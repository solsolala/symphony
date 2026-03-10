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

    def find(table, collection, filter, _opts) do
      collection
      |> all_docs(table)
      |> Enum.filter(&matches_filter?(&1, filter))
    end

    defp all_docs(collection, table) do
      :ets.tab2list(table)
      |> Enum.filter(fn
        {{^collection, _id}, _document} -> true
        _ -> false
      end)
      |> Enum.map(fn {{^collection, _id}, document} -> document end)
    end

    defp matches_filter?(document, %{"$or" => clauses}) when is_list(clauses) do
      Enum.any?(clauses, &matches_filter?(document, &1))
    end

    defp matches_filter?(document, %{"jira.account_id" => %{"$in" => values}}) do
      get_in(document, ["jira", "account_id"]) in values
    end

    defp matches_filter?(document, %{"jira.email" => %{"$in" => values}}) do
      get_in(document, ["jira", "email"]) in values
    end

    defp matches_filter?(document, %{"jira.display_name" => %{"$in" => values}}) do
      get_in(document, ["jira", "display_name"]) in values
    end

    defp matches_filter?(document, %{"jira.account_id" => value}) do
      get_in(document, ["jira", "account_id"]) == value
    end

    defp matches_filter?(document, %{"jira.email" => value}) do
      get_in(document, ["jira", "email"]) == value
    end

    defp matches_filter?(document, %{"jira.display_name" => value}) do
      get_in(document, ["jira", "display_name"]) == value
    end

    defp matches_filter?(_document, _filter), do: false
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
          "base_url" => "https://github.example.internal",
          "api_url" => "https://github.example.internal/api/v3",
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
    assert persisted["github"]["base_url"] == "https://github.example.internal"
    assert persisted["github"]["login"] == "octocat"
    assert persisted["recent_sessions"] |> Enum.map(& &1["session_id"]) == ["thread-1-turn-1"]

    assert %{"jira" => %{"token" => "super-secret-token"}, "github" => %{"token" => "ghp_super-secret-token"}} =
             FakeMongoApi.find_one(mongo_table, "browser_sessions", %{"_id" => "user-1"}, [])
  end

  test "finds an owner profile by jira assignee identity" do
    server = Module.concat(__MODULE__, OwnerStore)
    mongo_table = :ets.new(:owner_lookup, [:set, :public])

    {:ok, _pid} =
      BrowserSessionStore.start_link(
        name: server,
        mongo_api: FakeMongoApi,
        topology: mongo_table,
        collection: "browser_sessions"
      )

    BrowserSessionStore.upsert_profile(server, "user-owner", %{
      "user_id" => "user-owner",
      "jira" => %{
        "base_url" => "https://jira.company.internal",
        "token" => "jira-secret-token",
        "account_id" => "jira-account-123",
        "display_name" => "Jira Owner"
      },
      "github" => %{
        "base_url" => "https://github.example.internal",
        "api_url" => "https://github.example.internal/api/v3",
        "token" => "ghp_owner-token",
        "login" => "owner-login"
      }
    })

    assert %{"user_id" => "user-owner", "github" => %{"token" => "ghp_owner-token"}} =
             BrowserSessionStore.find_profile_for_issue(server, %{assignee_id: "jira-account-123"})
  end
end
