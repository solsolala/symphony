defmodule SymphonyElixir.JiraClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Jira.Client

  setup do
    jira_request_fun = Application.get_env(:symphony_elixir, :jira_request_fun)

    on_exit(fn ->
      if is_nil(jira_request_fun) do
        Application.delete_env(:symphony_elixir, :jira_request_fun)
      else
        Application.put_env(:symphony_elixir, :jira_request_fun, jira_request_fun)
      end
    end)

    :ok
  end

  test "fetch_candidate_issues queries jira search and normalizes issues" do
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_endpoint: "https://jira.company.internal",
      tracker_api_token: "jira-token",
      tracker_project_slug: "PLATFORM",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done"]
    )

    Application.put_env(:symphony_elixir, :jira_request_fun, fn req ->
      send(
        parent,
        {:jira_request, req.method, URI.to_string(req.url), Req.Request.get_option(req, :json), req.headers}
      )

      {:ok,
       %{
         status: 200,
         body: %{
           "startAt" => 0,
           "maxResults" => 50,
           "total" => 1,
           "issues" => [
             %{
               "key" => "PLATFORM-123",
               "fields" => %{
                 "summary" => "Fix Jira polling",
                 "description" => %{
                   "content" => [
                     %{
                       "content" => [
                         %{"text" => "Line one"},
                         %{"text" => "Line two"}
                       ]
                     }
                   ]
                 },
                 "priority" => %{"name" => "High"},
                 "status" => %{"name" => "In Progress"},
                 "labels" => ["backend", "jira"],
                 "issuelinks" => [
                   %{
                     "type" => %{"inward" => "is blocked by"},
                     "inwardIssue" => %{
                       "key" => "PLATFORM-99",
                       "fields" => %{"status" => %{"name" => "Done"}}
                     }
                   }
                 ],
                 "created" => "2026-03-09T01:02:03Z",
                 "updated" => "2026-03-09T02:03:04Z",
                 "assignee" => %{"accountId" => "acct-1"}
               }
             }
           ]
         }
       }}
    end)

    assert {:ok, [issue]} = Client.fetch_candidate_issues()

    assert_receive {:jira_request, :post, url, json, headers}
    assert url == "https://jira.company.internal/rest/api/2/search"
    assert get_header(headers, "authorization") == ["Bearer jira-token"]
    assert json["jql"] =~ ~s(project = "PLATFORM")
    assert json["jql"] =~ "status in (\"Todo\", \"In Progress\")"

    assert issue.id == "PLATFORM-123"
    assert issue.identifier == "PLATFORM-123"
    assert issue.title == "Fix Jira polling"
    assert issue.description == "Line one\nLine two"
    assert issue.priority == 2
    assert issue.state == "In Progress"
    assert issue.url == "https://jira.company.internal/browse/PLATFORM-123"
    assert issue.assignee_id == "acct-1"
    assert issue.labels == ["backend", "jira"]

    assert issue.blocked_by == [
             %{id: "PLATFORM-99", identifier: "PLATFORM-99", state: "Done"}
           ]
  end

  test "create_comment posts to jira comment api" do
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_endpoint: "https://jira.company.internal/rest/api/2",
      tracker_api_token: "jira-token",
      tracker_project_slug: "PLATFORM"
    )

    Application.put_env(:symphony_elixir, :jira_request_fun, fn req ->
      send(
        parent,
        {:jira_request, req.method, URI.to_string(req.url), Req.Request.get_option(req, :json)}
      )

      {:ok, %{status: 201, body: %{}}}
    end)

    assert :ok = Client.create_comment("PLATFORM-123", "hello jira")

    assert_receive {:jira_request, :post, url, json}
    assert url == "https://jira.company.internal/rest/api/2/issue/PLATFORM-123/comment"
    assert json == %{"body" => "hello jira"}
  end

  test "update_issue_state resolves transitions and posts matching transition id" do
    parent = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "jira",
      tracker_endpoint: "https://jira.company.internal",
      tracker_api_token: "jira-token",
      tracker_project_slug: "PLATFORM"
    )

    Application.put_env(:symphony_elixir, :jira_request_fun, fn req ->
      send(
        parent,
        {:jira_request, req.method, URI.to_string(req.url), Req.Request.get_option(req, :json)}
      )

      case {req.method, URI.to_string(req.url)} do
        {:get, "https://jira.company.internal/rest/api/2/issue/PLATFORM-123/transitions"} ->
          {:ok,
           %{
             status: 200,
             body: %{
               "transitions" => [
                 %{"id" => "11", "to" => %{"name" => "To Do"}},
                 %{"id" => "42", "to" => %{"name" => "Done"}}
               ]
             }
           }}

        {:post, "https://jira.company.internal/rest/api/2/issue/PLATFORM-123/transitions"} ->
          {:ok, %{status: 204, body: %{}}}
      end
    end)

    assert :ok = Client.update_issue_state("PLATFORM-123", "Done")

    assert_receive {:jira_request, :get, "https://jira.company.internal/rest/api/2/issue/PLATFORM-123/transitions", nil}

    assert_receive {:jira_request, :post, "https://jira.company.internal/rest/api/2/issue/PLATFORM-123/transitions", json}

    assert json == %{"transition" => %{"id" => "42"}}
  end

  defp get_header(headers, name) do
    headers
    |> Enum.find_value(fn
      {^name, value} -> value
      _ -> nil
    end)
  end
end
