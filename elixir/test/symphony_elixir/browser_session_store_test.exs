defmodule SymphonyElixir.BrowserSessionStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.BrowserSessionStore

  defmodule FakeMongoApi do
    def find_one(table, collection, filter, _opts) do
      case :ets.lookup(table, {collection, filter["_id"] || filter[:_id]}) do
        [{{^collection, _id}, document}] -> document
        [] -> nil
      end
    end

    def replace_one(table, collection, filter, replacement, _opts) do
      :ets.insert(table, {{collection, filter["_id"] || filter[:_id]}, replacement})
      {:ok, %{acknowledged: true}}
    end
  end

  test "persists authenticated user profiles and remembered sessions across restarts" do
    server = Module.concat(__MODULE__, Store)
    mongo_table = :ets.new(__MODULE__, [:set, :public])

    {:ok, pid} =
      BrowserSessionStore.start_link(
        name: server,
        mongo_api: FakeMongoApi,
        topology: mongo_table,
        collection: "browser_sessions",
        max_recent_sessions: 5
      )

    assert %{"user_id" => "user-1", "recent_sessions" => [], "github" => %{"has_token" => false}} =
             BrowserSessionStore.fetch_profile(server, "user-1")

    profile =
      BrowserSessionStore.upsert_profile(server, "user-1", %{
        "user_id" => "user-1",
        "authenticated_at" => "2026-03-10T09:00:00Z",
        "jira" => %{
          "base_url" => "https://jira.company.internal",
          "token" => "super-secret-token",
          "display_name" => "Jira User"
        },
        "github" => %{
          "token" => "ghp_super-secret-token",
          "login" => "octocat",
          "id" => "123"
        },
        "repository" => %{
          "clone_url" => "https://github.com/example/repo.git",
          "ref" => "main"
        }
      })

    assert profile["jira"]["base_url"] == "https://jira.company.internal"
    assert profile["jira"]["has_token"]
    assert profile["jira"]["display_name"] == "Jira User"
    assert profile["github"]["has_token"]
    assert profile["github"]["login"] == "octocat"
    assert profile["repository"]["clone_url"] == "https://github.com/example/repo.git"
    assert profile["authenticated_at"] == "2026-03-10T09:00:00Z"

    assert {:ok, profile} =
             BrowserSessionStore.capture_issue(server, "user-1", %{
               issue_identifier: "MT-1",
               issue_id: "issue-1",
               status: "running",
               workspace: %{path: "/tmp/workspaces/MT-1"},
               running: %{
                 session_id: "thread-1-turn-1",
                 thread_id: "thread-1",
                 turn_id: "turn-1",
                 turn_count: 3,
                 last_event_at: "2026-03-10T01:02:03Z"
               }
             })

    assert [recent_session] = profile["recent_sessions"]
    assert recent_session["issue_identifier"] == "MT-1"
    assert recent_session["thread_id"] == "thread-1"

    GenServer.stop(pid)

    {:ok, _pid} =
      BrowserSessionStore.start_link(
        name: server,
        mongo_api: FakeMongoApi,
        topology: mongo_table,
        collection: "browser_sessions",
        max_recent_sessions: 5
      )

    persisted = BrowserSessionStore.fetch_profile(server, "user-1")
    assert persisted["jira"]["base_url"] == "https://jira.company.internal"
    assert persisted["jira"]["has_token"]
    assert persisted["github"]["login"] == "octocat"
    assert persisted["recent_sessions"] |> Enum.map(& &1["session_id"]) == ["thread-1-turn-1"]

    assert %{"jira" => %{"token" => "super-secret-token"}, "github" => %{"token" => "ghp_super-secret-token"}} =
             FakeMongoApi.find_one(mongo_table, "browser_sessions", %{"_id" => "user-1"}, [])
  end
end
