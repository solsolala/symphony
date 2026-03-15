defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias SymphonyElixir.Jira.Adapter, as: JiraAdapter
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule FakeJiraClient do
    def fetch_candidate_issues do
      send(self(), :jira_fetch_candidate_issues_called)
      {:ok, [:jira_candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:jira_fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:jira_fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def create_comment(issue_id, body) do
      send(self(), {:jira_create_comment_called, issue_id, body})
      :ok
    end

    def update_issue_state(issue_id, state_name) do
      send(self(), {:jira_update_issue_state_called, issue_id, state_name})
      :ok
    end
  end

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
      :ets.tab2list(table)
      |> Enum.filter(fn
        {{^collection, _id}, document} -> matches_filter?(document, filter)
        _ -> false
      end)
      |> Enum.map(fn {{^collection, _id}, document} -> document end)
    end

    defp matches_filter?(document, %{"$or" => clauses}) when is_list(clauses) do
      Enum.any?(clauses, &matches_filter?(document, &1))
    end

    defp matches_filter?(document, %{"jira.account_id" => value}) when is_binary(value) do
      get_in(document, ["jira", "account_id"]) == value
    end

    defp matches_filter?(document, %{"jira.account_id" => %{"$in" => values}}) do
      get_in(document, ["jira", "account_id"]) in values
    end

    defp matches_filter?(document, %{"jira.email" => value}) when is_binary(value) do
      get_in(document, ["jira", "email"]) == value
    end

    defp matches_filter?(document, %{"jira.email" => %{"$in" => values}}) do
      get_in(document, ["jira", "email"]) in values
    end

    defp matches_filter?(document, %{"jira.display_name" => value}) when is_binary(value) do
      get_in(document, ["jira", "display_name"]) == value
    end

    defp matches_filter?(document, %{"jira.display_name" => %{"$in" => values}}) do
      get_in(document, ["jira", "display_name"]) in values
    end

    defp matches_filter?(_document, _filter), do: false
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)
    jira_client_module = Application.get_env(:symphony_elixir, :jira_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end

      if is_nil(jira_client_module) do
        Application.delete_env(:symphony_elixir, :jira_client_module)
      else
        Application.put_env(:symphony_elixir, :jira_client_module, jira_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    browser_session_store = Application.get_env(:symphony_elixir, :browser_session_store)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)

      if is_nil(browser_session_store) do
        Application.delete_env(:symphony_elixir, :browser_session_store)
      else
        Application.put_env(:symphony_elixir, :browser_session_store, browser_session_store)
      end
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.tracker_kind() == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")
    assert SymphonyElixir.Tracker.adapter() == JiraAdapter

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "jira adapter delegates reads and writes" do
    Application.put_env(:symphony_elixir, :jira_client_module, FakeJiraClient)

    assert {:ok, [:jira_candidate]} = JiraAdapter.fetch_candidate_issues()
    assert_receive :jira_fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = JiraAdapter.fetch_issues_by_states(["Todo"])
    assert_receive {:jira_fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = JiraAdapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:jira_fetch_issue_states_by_ids_called, ["issue-1"]}

    assert :ok = JiraAdapter.create_comment("issue-1", "hello")
    assert_receive {:jira_create_comment_called, "issue-1", "hello"}

    assert :ok = JiraAdapter.update_issue_state("issue-1", "Done")
    assert_receive {:jira_update_issue_state_called, "issue-1", "Done"}
  end

  test "client session api persists authenticated user metadata and remembered sessions" do
    store_name = Module.concat(__MODULE__, BrowserSessionStore)
    Application.put_env(:symphony_elixir, :browser_session_store, store_name)
    mongo_table = :ets.new(__MODULE__, [:set, :public])
    store_opts = [name: store_name, mongo_api: FakeMongoApi, topology: mongo_table, collection: "browser_sessions"]

    start_supervised!({SymphonyElixir.BrowserSessionStore, store_opts})

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ClientSessionApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn =
      build_conn()
      |> init_test_session(%{user_id: "user-123"})
      |> get("/api/v1/session")

    body = json_response(conn, 200)
    client_id = body["client_id"]
    assert body["user_id"] == "user-123"

    assert is_binary(client_id)
    refute body["profile"]["jira"]["has_token"]
    refute body["profile"]["github"]["has_token"]

    conn =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> put("/api/v1/session", %{
        jira: %{base_url: "https://jira.company.internal", token: "secret-token"},
        github: %{token: "ghp_secret-token", login: "octocat"},
        repository: %{clone_url: "https://github.com/example/repo.git", ref: "main"}
      })

    updated = json_response(conn, 200)
    assert updated["client_id"] == client_id
    assert updated["user_id"] == "user-123"
    assert updated["profile"]["jira"]["base_url"] == "https://jira.company.internal"
    assert updated["profile"]["jira"]["has_token"]
    assert updated["profile"]["github"]["has_token"]
    assert updated["profile"]["github"]["login"] == "octocat"
    assert updated["profile"]["repository"]["clone_url"] == "https://github.com/example/repo.git"

    conn =
      conn
      |> recycle()
      |> post("/api/v1/session/issues/MT-HTTP/capture", %{})

    captured = json_response(conn, 200)

    assert [%{"issue_identifier" => "MT-HTTP", "session_id" => "thread-http"} | _] =
             captured["profile"]["recent_sessions"]

    conn = recycle(conn)
    fetched_again = json_response(get(conn, "/api/v1/session"), 200)
    assert fetched_again["client_id"] == client_id
    assert fetched_again["user_id"] == "user-123"
    assert fetched_again["profile"]["recent_sessions"] |> Enum.map(& &1["issue_identifier"]) == ["MT-HTTP"]

    missing =
      conn
      |> recycle()
      |> post("/api/v1/session/issues/MT-MISSING/capture", %{})
      |> json_response(404)

    assert missing == %{"error" => %{"code" => "issue_not_found", "message" => "Issue not found"}}
  end

  test "token login verifies jira and github identities and persists an authenticated user session" do
    store_name = Module.concat(__MODULE__, LoginBrowserSessionStore)
    Application.put_env(:symphony_elixir, :browser_session_store, store_name)
    Application.put_env(:symphony_elixir, :default_jira_base_url, "https://jira.company.internal")
    mongo_table = :ets.new(:login_browser_sessions, [:set, :public])
    store_opts = [name: store_name, mongo_api: FakeMongoApi, topology: mongo_table, collection: "browser_sessions"]

    start_supervised!({SymphonyElixir.BrowserSessionStore, store_opts})

    Application.put_env(:symphony_elixir, :auth_jira_request_fun, fn req ->
      send(self(), {:auth_jira_request, req.method, URI.to_string(req.url)})

      {:ok,
       %{
         status: 200,
         body: %{
           "accountId" => "jira-user-1",
           "displayName" => "Jira User",
           "emailAddress" => "jira@example.com"
         }
       }}
    end)

    Application.put_env(:symphony_elixir, :auth_github_request_fun, fn req ->
      send(self(), {:auth_github_request, req.method, URI.to_string(req.url)})

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => 123,
           "login" => "octocat",
           "name" => "The Octocat",
           "html_url" => "https://github.com/octocat",
           "avatar_url" => "https://avatars.githubusercontent.com/u/123?v=4"
         }
       }}
    end)

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :LoginOrchestrator), snapshot_timeout_ms: 50)

    conn =
      build_conn()
      |> post("/login", %{
        "jira_base_url" => "https://jira.company.internal",
        "github_base_url" => "https://github.company.internal",
        "jira_token" => "jira-secret-token",
        "github_token" => "ghp_secret-token"
      })

    assert redirected_to(conn) == "/"
    assert get_session(conn, :user_id) =~ "user-"
    assert_receive {:auth_jira_request, :get, "https://jira.company.internal/rest/api/2/myself"}
    assert_receive {:auth_github_request, :get, "https://github.company.internal/api/v3/user"}

    session_body =
      conn
      |> recycle()
      |> get("/api/v1/session")
      |> json_response(200)

    assert session_body["profile"]["user_id"] == session_body["user_id"]
    assert session_body["profile"]["jira"]["base_url"] == "https://jira.company.internal"
    assert session_body["profile"]["jira"]["display_name"] == "Jira User"
    assert session_body["profile"]["github"]["base_url"] == "https://github.company.internal"
    assert session_body["profile"]["github"]["login"] == "octocat"
    assert session_body["profile"]["github"]["has_token"]

    assert %{"jira" => %{"token" => "jira-secret-token"}, "github" => %{"token" => "ghp_secret-token"}} =
             FakeMongoApi.find_one(mongo_table, "browser_sessions", %{"_id" => session_body["user_id"]}, [])
  end

  test "token login uses deployment defaults when base urls are left blank" do
    store_name = Module.concat(__MODULE__, DefaultLoginBrowserSessionStore)
    Application.put_env(:symphony_elixir, :browser_session_store, store_name)
    Application.put_env(:symphony_elixir, :default_jira_base_url, "https://jira.default.internal")
    Application.put_env(:symphony_elixir, :default_github_base_url, "https://github.default.internal")
    mongo_table = :ets.new(:default_login_browser_sessions, [:set, :public])
    store_opts = [name: store_name, mongo_api: FakeMongoApi, topology: mongo_table, collection: "browser_sessions"]

    start_supervised!({SymphonyElixir.BrowserSessionStore, store_opts})

    Application.put_env(:symphony_elixir, :auth_jira_request_fun, fn req ->
      send(self(), {:default_auth_jira_request, req.method, URI.to_string(req.url)})

      {:ok,
       %{
         status: 200,
         body: %{
           "accountId" => "jira-user-1",
           "displayName" => "Jira User"
         }
       }}
    end)

    Application.put_env(:symphony_elixir, :auth_github_request_fun, fn req ->
      send(self(), {:default_auth_github_request, req.method, URI.to_string(req.url)})

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => 123,
           "login" => "octocat"
         }
       }}
    end)

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :DefaultLoginOrchestrator), snapshot_timeout_ms: 50)

    conn =
      build_conn()
      |> post("/login", %{
        "jira_base_url" => "",
        "github_base_url" => "",
        "jira_token" => "jira-secret-token",
        "github_token" => "ghp_secret-token"
      })

    assert redirected_to(conn) == "/"
    assert_receive {:default_auth_jira_request, :get, "https://jira.default.internal/rest/api/2/myself"}
    assert_receive {:default_auth_github_request, :get, "https://github.default.internal/api/v3/user"}

    session_body =
      conn
      |> recycle()
      |> get("/api/v1/session")
      |> json_response(200)

    assert session_body["profile"]["jira"]["base_url"] == "https://jira.default.internal"
    assert session_body["profile"]["github"]["base_url"] == "https://github.default.internal"
  end

  test "login form and token auth use runtime env defaults" do
    previous_jira_default = System.get_env("SYMPHONY_DEFAULT_JIRA_BASE_URL")
    previous_github_default = System.get_env("SYMPHONY_DEFAULT_GITHUB_BASE_URL")

    on_exit(fn ->
      restore_env("SYMPHONY_DEFAULT_JIRA_BASE_URL", previous_jira_default)
      restore_env("SYMPHONY_DEFAULT_GITHUB_BASE_URL", previous_github_default)
    end)

    System.put_env("SYMPHONY_DEFAULT_JIRA_BASE_URL", "https://jira.runtime.internal")
    System.put_env("SYMPHONY_DEFAULT_GITHUB_BASE_URL", "https://github.runtime.internal")
    Application.delete_env(:symphony_elixir, :default_jira_base_url)
    Application.delete_env(:symphony_elixir, :default_github_base_url)

    store_name = Module.concat(__MODULE__, RuntimeDefaultLoginBrowserSessionStore)
    Application.put_env(:symphony_elixir, :browser_session_store, store_name)
    mongo_table = :ets.new(:runtime_default_login_browser_sessions, [:set, :public])
    store_opts = [name: store_name, mongo_api: FakeMongoApi, topology: mongo_table, collection: "browser_sessions"]

    start_supervised!({SymphonyElixir.BrowserSessionStore, store_opts})

    Application.put_env(:symphony_elixir, :auth_jira_request_fun, fn req ->
      send(self(), {:runtime_auth_jira_request, req.method, URI.to_string(req.url)})

      {:ok,
       %{
         status: 200,
         body: %{
           "accountId" => "jira-user-1",
           "displayName" => "Jira User"
         }
       }}
    end)

    Application.put_env(:symphony_elixir, :auth_github_request_fun, fn req ->
      send(self(), {:runtime_auth_github_request, req.method, URI.to_string(req.url)})

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => 123,
           "login" => "octocat"
         }
       }}
    end)

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :RuntimeDefaultLoginOrchestrator), snapshot_timeout_ms: 50)

    login_page =
      build_conn()
      |> get("/")
      |> html_response(200)

    assert login_page =~ "https://jira.runtime.internal"
    assert login_page =~ "https://github.runtime.internal"

    conn =
      build_conn()
      |> post("/login", %{
        "jira_base_url" => "",
        "github_base_url" => "",
        "jira_token" => "jira-secret-token",
        "github_token" => "ghp_secret-token"
      })

    assert redirected_to(conn) == "/"
    assert_receive {:runtime_auth_jira_request, :get, "https://jira.runtime.internal/rest/api/2/myself"}
    assert_receive {:runtime_auth_github_request, :get, "https://github.runtime.internal/api/v3/user"}
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "session_id" => "thread-http",
                 "thread_id" => nil,
                 "turn_id" => nil,
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom"
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{"path" => Path.join(Config.workspace_root(), "MT-HTTP")},
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "session_id" => "thread-http",
               "thread_id" => nil,
               "turn_id" => nil,
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(authenticated_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(authenticated_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp authenticated_conn(user_id \\ "user-test") do
    build_conn()
    |> init_test_session(%{user_id: user_id})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
