defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Thin Jira REST client for polling candidate issues and updating issue state.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000
  @search_fields [
    "summary",
    "description",
    "priority",
    "status",
    "labels",
    "issuelinks",
    "created",
    "updated",
    "assignee"
  ]
  @priority_name_ranks %{
    "highest" => 1,
    "high" => 2,
    "medium" => 3,
    "low" => 4,
    "lowest" => 4,
    "critical" => 1,
    "major" => 2,
    "minor" => 3,
    "trivial" => 4,
    "blocker" => 1
  }

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with :ok <- require_jira_connection(),
         project_slug when is_binary(project_slug) <- Config.jira_project_slug() || {:error, :missing_jira_project_slug} do
      search_issues(candidate_jql(project_slug, Config.tracker_active_states()))
    else
      {:error, _reason} = error -> error
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      with :ok <- require_jira_connection(),
           project_slug when is_binary(project_slug) <- Config.jira_project_slug() || {:error, :missing_jira_project_slug} do
        search_issues(candidate_jql(project_slug, normalized_states))
      else
        {:error, _reason} = error -> error
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids =
      issue_ids
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ids == [] do
      {:ok, []}
    else
      with :ok <- require_jira_connection() do
        search_issues(issue_ids_jql(ids))
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with :ok <- require_jira_connection(),
         {:ok, %{status: status}} when status in 200..299 <-
           request(:post, "/issue/#{encode_path_segment(issue_id)}/comment", json: %{"body" => body}) do
      :ok
    else
      {:ok, response} ->
        Logger.error("Jira comment creation failed status=#{response.status} body=#{summarize_error_body(response.body)}")
        {:error, :comment_create_failed}

      {:error, _reason} = error ->
        error
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with :ok <- require_jira_connection(),
         {:ok, transition_id} <- resolve_transition_id(issue_id, state_name),
         {:ok, %{status: status}} when status in 200..299 <-
           request(
             :post,
             "/issue/#{encode_path_segment(issue_id)}/transitions",
             json: %{"transition" => %{"id" => transition_id}}
           ) do
      :ok
    else
      {:ok, response} ->
        Logger.error("Jira issue transition failed status=#{response.status} body=#{summarize_error_body(response.body)}")
        {:error, :issue_update_failed}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue), do: normalize_issue(issue)

  defp search_issues(jql) when is_binary(jql) do
    do_search_issues(jql, 0, [])
  end

  defp do_search_issues(jql, start_at, acc) when is_binary(jql) and is_integer(start_at) do
    case request(:post, "/search", json: search_payload(jql, start_at)) do
      {:ok, %{status: 200, body: body}} ->
        with {:ok, issues, page_info} <- decode_search_response(body) do
          updated_acc = Enum.reverse(issues, acc)

          if page_info.has_next_page do
            do_search_issues(jql, page_info.next_start_at, updated_acc)
          else
            {:ok, Enum.reverse(updated_acc)}
          end
        end

      {:ok, response} ->
        Logger.error("Jira search request failed status=#{response.status} jql=#{inspect(jql)} body=#{summarize_error_body(response.body)}")
        {:error, {:jira_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Jira search request failed jql=#{inspect(jql)} reason=#{inspect(reason)}")
        {:error, {:jira_api_request, reason}}
    end
  end

  defp resolve_transition_id(issue_id, state_name) do
    case request(:get, "/issue/#{encode_path_segment(issue_id)}/transitions") do
      {:ok, %{status: 200, body: body}} ->
        transitions = Map.get(body, "transitions", [])

        transitions
        |> Enum.find_value(fn
          %{"id" => transition_id, "to" => %{"name" => name}}
          when is_binary(transition_id) and is_binary(name) ->
            if normalize_issue_state(name) == normalize_issue_state(state_name) do
              transition_id
            end

          _ ->
            nil
        end)
        |> case do
          transition_id when is_binary(transition_id) -> {:ok, transition_id}
          _ -> {:error, :state_not_found}
        end

      {:ok, response} ->
        Logger.error("Jira transition lookup failed status=#{response.status} body=#{summarize_error_body(response.body)}")
        {:error, {:jira_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Jira transition lookup failed: #{inspect(reason)}")
        {:error, {:jira_api_request, reason}}
    end
  end

  defp search_payload(jql, start_at) do
    %{
      "jql" => jql,
      "fields" => @search_fields,
      "startAt" => start_at,
      "maxResults" => @issue_page_size
    }
  end

  defp decode_search_response(%{"issues" => issues} = body) when is_list(issues) do
    normalized_issues =
      issues
      |> Enum.map(&normalize_issue/1)
      |> Enum.reject(&is_nil/1)

    start_at = integer_or_default(body["startAt"], 0)
    max_results = integer_or_default(body["maxResults"], length(issues))
    total = integer_or_default(body["total"], start_at + length(issues))
    next_start_at = start_at + max_results

    {:ok, normalized_issues, %{has_next_page: next_start_at < total, next_start_at: next_start_at}}
  end

  defp decode_search_response(%{"errorMessages" => errors}) when is_list(errors) do
    {:error, {:jira_api_errors, errors}}
  end

  defp decode_search_response(_body), do: {:error, :jira_unknown_payload}

  defp normalize_issue(%{"key" => issue_key, "fields" => fields})
       when is_binary(issue_key) and is_map(fields) do
    assignee = Map.get(fields, "assignee")

    %Issue{
      id: issue_key,
      identifier: issue_key,
      title: normalize_string(fields["summary"]),
      description: normalize_description(fields["description"]),
      priority: normalize_priority(fields["priority"]),
      state: get_in(fields, ["status", "name"]),
      branch_name: nil,
      url: issue_browser_url(issue_key),
      assignee_id: assignee_id(assignee),
      blocked_by: extract_blockers(fields["issuelinks"]),
      labels: extract_labels(fields["labels"]),
      assigned_to_worker: true,
      created_at: parse_datetime(fields["created"]),
      updated_at: parse_datetime(fields["updated"])
    }
  end

  defp normalize_issue(_issue), do: nil

  defp extract_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_labels), do: []

  defp extract_blockers(links) when is_list(links) do
    Enum.flat_map(links, fn
      %{"type" => type, "inwardIssue" => blocker_issue} when is_map(type) and is_map(blocker_issue) ->
        if blocked_by_link?(type) do
          [
            %{
              id: blocker_issue["key"] || blocker_issue["id"],
              identifier: blocker_issue["key"],
              state: get_in(blocker_issue, ["fields", "status", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_links), do: []

  defp blocked_by_link?(%{"inward" => inward}) when is_binary(inward) do
    inward
    |> String.downcase()
    |> String.contains?("block")
  end

  defp blocked_by_link?(_type), do: false

  defp assignee_id(%{} = assignee) do
    assignee["accountId"] || assignee["name"] || assignee["key"] || assignee["emailAddress"]
  end

  defp assignee_id(_assignee), do: nil

  defp normalize_priority(%{"name" => name}) when is_binary(name) do
    Map.get(@priority_name_ranks, String.downcase(String.trim(name)))
  end

  defp normalize_priority(_priority), do: nil

  defp normalize_description(nil), do: nil

  defp normalize_description(description) when is_binary(description) do
    normalize_string(description)
  end

  defp normalize_description(%{"content" => content}) when is_list(content) do
    content
    |> flatten_description_nodes()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> normalize_string()
  end

  defp normalize_description(description) when is_map(description) do
    description
    |> Map.values()
    |> flatten_description_nodes()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> normalize_string()
  end

  defp normalize_description(_description), do: nil

  defp flatten_description_nodes(values) when is_list(values) do
    Enum.flat_map(values, &flatten_description_nodes/1)
  end

  defp flatten_description_nodes(%{"text" => text}) when is_binary(text) do
    [String.trim(text)]
  end

  defp flatten_description_nodes(%{"content" => content}) when is_list(content) do
    flatten_description_nodes(content)
  end

  defp flatten_description_nodes(%{} = node) do
    node
    |> Map.values()
    |> flatten_description_nodes()
  end

  defp flatten_description_nodes(value) when is_binary(value), do: [String.trim(value)]
  defp flatten_description_nodes(_value), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive_datetime} -> DateTime.from_naive!(naive_datetime, "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp parse_datetime(_value), do: nil

  defp candidate_jql(project_slug, state_names) do
    ~s|project = "#{escape_jql(project_slug)}" AND status in (#{quoted_jql_values(state_names)}) ORDER BY created ASC|
  end

  defp issue_ids_jql(issue_ids) do
    ~s|issuekey in (#{quoted_jql_values(issue_ids)})|
  end

  defp quoted_jql_values(values) do
    Enum.map_join(values, ", ", fn value -> ~s("#{escape_jql(value)}") end)
  end

  defp escape_jql(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp request(method, path, opts \\ []) when is_atom(method) and is_binary(path) and is_list(opts) do
    req =
      Req.new(
        method: method,
        url: jira_api_url(path),
        headers: jira_headers(),
        connect_options: [timeout: 30_000]
      )
      |> maybe_put_json(opts[:json])
      |> maybe_put_params(opts[:params])

    request_fun().(req)
  end

  defp maybe_put_json(req, nil), do: req
  defp maybe_put_json(req, json), do: Req.Request.put_new_option(req, :json, json)

  defp maybe_put_params(req, nil), do: req
  defp maybe_put_params(req, params), do: Req.Request.put_new_option(req, :params, params)

  defp request_fun do
    Application.get_env(:symphony_elixir, :jira_request_fun, &Req.request/1)
  end

  defp jira_headers do
    [
      {"authorization", "Bearer #{Config.jira_api_token()}"},
      {"accept", "application/json"},
      {"content-type", "application/json"}
    ]
  end

  defp jira_api_url(path) when is_binary(path) do
    jira_api_root() <> path
  end

  defp jira_api_root do
    endpoint = Config.jira_endpoint() || ""

    if String.contains?(endpoint, "/rest/api/") do
      String.trim_trailing(endpoint, "/")
    else
      String.trim_trailing(endpoint, "/") <> "/rest/api/2"
    end
  end

  defp issue_browser_url(issue_key) when is_binary(issue_key) do
    jira_browser_root() <> "/browse/" <> issue_key
  end

  defp jira_browser_root do
    endpoint = Config.jira_endpoint() || ""

    endpoint
    |> String.split("/rest/api/", parts: 2)
    |> hd()
    |> String.trim_trailing("/")
  end

  defp require_jira_connection do
    cond do
      is_nil(Config.jira_endpoint()) ->
        {:error, :missing_jira_endpoint}

      is_nil(Config.jira_api_token()) ->
        {:error, :missing_jira_api_token}

      true ->
        :ok
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp integer_or_default(value, _default) when is_integer(value), do: value
  defp integer_or_default(_value, default), do: default

  defp encode_path_segment(value) do
    URI.encode(value)
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
end
