defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Jira client for fetching and updating issues.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Jira.Issue

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    project_slug = Config.jira_project_slug()

    cond do
      is_nil(Config.jira_api_token()) ->
        {:error, :missing_jira_api_token}

      is_nil(project_slug) ->
        {:error, :missing_jira_project_slug}

      true ->
        do_fetch_by_states(project_slug, Config.jira_active_states())
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      project_slug = Config.jira_project_slug()

      cond do
        is_nil(Config.jira_api_token()) ->
          {:error, :missing_jira_api_token}

        is_nil(project_slug) ->
          {:error, :missing_jira_project_slug}

        true ->
          do_fetch_by_states(project_slug, normalized_states)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids)
    end
  end

  @spec rest_post(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def rest_post(path, body \\ %{}, opts \\ []) when is_binary(path) and is_map(body) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &post_rest_request/3)

    with {:ok, headers} <- rest_headers(),
         {:ok, %{status: status, body: response_body}} when status in 200..299 <- request_fun.(path, body, headers) do
      {:ok, response_body}
    else
      {:ok, response} ->
        Logger.error(
          "Jira REST API request failed status=#{response.status} path=#{path} " <>
            jira_error_context(response)
        )

        {:error, {:jira_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Jira REST API request failed: #{inspect(reason)}")
        {:error, {:jira_api_request, reason}}
    end
  end

  defp do_fetch_by_states(project_slug, state_names) do
    states_jql =
      state_names
      |> Enum.map(&"\"#{&1}\"")
      |> Enum.join(", ")

    jql = "project = \"#{project_slug}\" AND status IN (#{states_jql}) ORDER BY created ASC"

    do_fetch_paginated_jql(jql, 0, [])
  end

  defp do_fetch_issue_states(ids) do
    ids_jql =
      ids
      |> Enum.map(&"\"#{&1}\"")
      |> Enum.join(", ")

    jql = "id IN (#{ids_jql})"

    do_fetch_paginated_jql(jql, 0, [])
  end

  defp do_fetch_paginated_jql(jql, start_at, acc_issues) do
    payload = %{
      "jql" => jql,
      "startAt" => start_at,
      "maxResults" => @issue_page_size,
      "fields" => ["summary", "description", "priority", "status", "assignee", "labels", "issuelinks", "created", "updated"]
    }

    case rest_post("/search", payload) do
      {:ok, %{"issues" => issues, "total" => total, "startAt" => response_start_at, "maxResults" => response_max_results}} ->
        normalized_issues = Enum.map(issues, &normalize_issue/1) |> Enum.reject(&is_nil/1)
        updated_acc = Enum.reverse(normalized_issues, acc_issues)

        next_start_at = response_start_at + response_max_results

        if next_start_at < total do
          do_fetch_paginated_jql(jql, next_start_at, updated_acc)
        else
          {:ok, Enum.reverse(updated_acc)}
        end

      {:ok, response} ->
        Logger.error("Unexpected Jira API response format: #{inspect(response)}")
        {:error, :jira_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp jira_error_context(response) do
    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    "body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp rest_headers do
    case Config.jira_api_token() do
      nil ->
        {:error, :missing_jira_api_token}

      token ->
        {:ok,
         [
           {"Authorization", "Basic #{token}"},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_rest_request(path, body, headers) do
    endpoint = Config.jira_endpoint() || ""
    url = String.trim_trailing(endpoint, "/") <> path

    Req.post(url,
      headers: headers,
      json: body,
      connect_options: [timeout: 30_000]
    )
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue)
  end

  defp normalize_issue(issue) when is_map(issue) do
    fields = issue["fields"] || %{}

    %Issue{
      id: issue["id"],
      identifier: issue["key"],
      title: fields["summary"],
      description: fields["description"],
      priority: parse_priority(fields["priority"]),
      state: get_in(fields, ["status", "name"]),
      branch_name: nil,
      url: build_issue_url(issue["key"]),
      assignee_id: get_in(fields, ["assignee", "accountId"]),
      blocked_by: extract_blockers(fields["issuelinks"]),
      labels: extract_labels(fields["labels"]),
      assigned_to_worker: true,
      created_at: parse_datetime(fields["created"]),
      updated_at: parse_datetime(fields["updated"])
    }
  end

  defp normalize_issue(_issue), do: nil

  defp build_issue_url(key) when is_binary(key) do
    endpoint = Config.jira_endpoint() || ""
    base_url = endpoint |> URI.parse() |> Map.put(:path, nil) |> URI.to_string()
    "#{base_url}/browse/#{key}"
  end

  defp build_issue_url(_), do: nil

  defp extract_labels(labels) when is_list(labels) do
    labels
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(issuelinks) when is_list(issuelinks) do
    issuelinks
    |> Enum.flat_map(fn link ->
      type = get_in(link, ["type", "name"])

      cond do
        is_nil(type) ->
          []

        String.downcase(type) == "blocks" and Map.has_key?(link, "inwardIssue") ->
          # If inwardIssue exists and type is blocks, it means inwardIssue is blocking THIS issue.
          inward = link["inwardIssue"]

          [
            %{
              id: inward["id"],
              identifier: inward["key"],
              state: get_in(inward, ["fields", "status", "name"])
            }
          ]

        true ->
          []
      end
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(%{"id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {num, _} -> num
      _ -> nil
    end
  end

  defp parse_priority(_), do: nil
end
