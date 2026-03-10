defmodule SymphonyElixir.BrowserSessionStore do
  @moduledoc """
  Persists user-scoped Jira, GitHub, repository, and Codex session metadata in MongoDB.

  The historical module name is retained for compatibility with the existing
  observability API and tests, but the stored profiles are keyed by the
  authenticated Symphony user identifier.
  """

  use GenServer

  require Logger

  @default_max_recent_sessions 20

  @type profile :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec fetch_profile(String.t()) :: profile()
  def fetch_profile(profile_id), do: fetch_profile(__MODULE__, profile_id)

  @spec fetch_profile(GenServer.server(), String.t()) :: profile()
  def fetch_profile(server, profile_id) when is_binary(profile_id) do
    GenServer.call(server, {:fetch_profile, profile_id})
  end

  @spec touch(String.t()) :: profile()
  def touch(profile_id), do: touch(__MODULE__, profile_id)

  @spec touch(GenServer.server(), String.t()) :: profile()
  def touch(server, profile_id) when is_binary(profile_id) do
    GenServer.call(server, {:touch, profile_id})
  end

  @spec upsert_profile(String.t(), map()) :: profile()
  def upsert_profile(profile_id, attrs), do: upsert_profile(__MODULE__, profile_id, attrs)

  @spec upsert_profile(GenServer.server(), String.t(), map()) :: profile()
  def upsert_profile(server, profile_id, attrs) when is_binary(profile_id) and is_map(attrs) do
    GenServer.call(server, {:upsert_profile, profile_id, attrs})
  end

  @spec capture_issue(String.t(), map()) :: {:ok, profile()} | {:error, term()}
  def capture_issue(profile_id, issue_payload), do: capture_issue(__MODULE__, profile_id, issue_payload)

  @spec capture_issue(GenServer.server(), String.t(), map()) ::
          {:ok, profile()} | {:error, term()}
  def capture_issue(server, profile_id, issue_payload)
      when is_binary(profile_id) and is_map(issue_payload) do
    GenServer.call(server, {:capture_issue, profile_id, issue_payload})
  end

  @spec find_profile_for_issue(map()) :: profile() | nil
  def find_profile_for_issue(issue), do: find_profile_for_issue(__MODULE__, issue)

  @spec find_profile_for_issue(GenServer.server(), map()) :: profile() | nil
  def find_profile_for_issue(server, issue) when is_map(issue) do
    GenServer.call(server, {:find_profile_for_issue, issue})
  end

  @impl true
  def init(opts) do
    explicit_mongo? = Keyword.has_key?(opts, :mongo_api) or Keyword.has_key?(opts, :topology)

    {:ok,
     %{
       mongo_api: Keyword.get(opts, :mongo_api, Mongo),
       topology: Keyword.get(opts, :topology, mongo_topology()),
       collection: Keyword.get(opts, :collection, mongo_collection()),
       mongo_enabled?: Keyword.get(opts, :mongo_enabled?, explicit_mongo? or mongo_uri_present?()),
       max_recent_sessions: Keyword.get(opts, :max_recent_sessions, @default_max_recent_sessions),
       clients: %{}
     }}
  end

  @impl true
  def handle_call({:fetch_profile, profile_id}, _from, state) do
    {profile, state} = load_profile(state, profile_id)
    {:reply, public_profile(profile), state}
  end

  def handle_call({:touch, profile_id}, _from, state) do
    {profile, state} = load_profile(state, profile_id)
    profile = touch_profile(profile)
    state = persist_profile(state, profile_id, profile)
    {:reply, public_profile(profile), state}
  end

  def handle_call({:upsert_profile, profile_id, attrs}, _from, state) do
    {profile, state} = load_profile(state, profile_id)
    profile = merge_profile(profile, attrs)
    state = persist_profile(state, profile_id, profile)
    {:reply, public_profile(profile), state}
  end

  def handle_call({:capture_issue, profile_id, issue_payload}, _from, state) do
    {profile, state} = load_profile(state, profile_id)

    case recent_session_from_issue_payload(issue_payload) do
      {:ok, recent_session} ->
        profile = put_recent_session(profile, recent_session, state.max_recent_sessions)
        state = persist_profile(state, profile_id, profile)
        {:reply, {:ok, public_profile(profile)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:find_profile_for_issue, issue}, _from, state) do
    {profile, state} = find_profile_by_issue(state, issue)
    {:reply, profile, state}
  end

  defp load_profile(state, profile_id) do
    cached_profile = Map.get(state.clients, profile_id)

    if state.mongo_enabled? do
      case safe_find_one(state, profile_id) do
        %{} = document ->
          profile = normalize_profile(document, profile_id)
          {profile, %{state | clients: Map.put(state.clients, profile_id, profile)}}

        nil ->
          {cached_profile || default_profile(profile_id), state}

        {:error, reason} ->
          Logger.warning("Failed to fetch session profile profile_id=#{profile_id}: #{inspect(reason)}")
          {cached_profile || default_profile(profile_id), state}
      end
    else
      {cached_profile || default_profile(profile_id), state}
    end
  end

  defp find_profile_by_issue(state, issue) do
    assignee_candidates = issue_assignee_candidates(issue)

    case find_cached_profile_by_assignee(state.clients, assignee_candidates) do
      nil ->
        if state.mongo_enabled? and assignee_candidates != [] do
          case safe_find_profiles(state, assignee_candidates) do
            [%{} = document | _rest] ->
              profile_id = document["_id"] || document[:_id] || document["user_id"] || document[:user_id]
              profile = normalize_profile(document, to_string(profile_id))
              {profile, %{state | clients: Map.put(state.clients, profile["user_id"], profile)}}

            [] ->
              {nil, state}

            {:error, reason} ->
              Logger.warning("Failed to find issue owner profile assignees=#{inspect(assignee_candidates)}: #{inspect(reason)}")
              {nil, state}
          end
        else
          {nil, state}
        end

      profile ->
        {profile, state}
    end
  end

  defp persist_profile(state, profile_id, profile) do
    state = %{state | clients: Map.put(state.clients, profile_id, profile)}

    if state.mongo_enabled? do
      document = Map.put(profile, "_id", profile_id)

      case safe_replace_one(state, profile_id, document) do
        {:ok, _result} ->
          state

        :ok ->
          state

        {:error, reason} ->
          Logger.warning("Failed to persist session profile profile_id=#{profile_id}: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp mongo_uri_present? do
    case Application.get_env(:symphony_elixir, :mongodb_uri) do
      uri when is_binary(uri) -> String.trim(uri) != ""
      _ -> false
    end
  end

  defp mongo_topology do
    Application.get_env(:symphony_elixir, :mongodb_topology, SymphonyElixir.Mongo)
  end

  defp mongo_collection do
    Application.get_env(:symphony_elixir, :browser_session_store_collection, "user_sessions")
  end

  defp safe_find_one(state, profile_id) do
    state.mongo_api.find_one(state.topology, state.collection, %{"_id" => profile_id}, [])
  rescue
    error ->
      {:error, {:exception, error}}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp safe_replace_one(state, profile_id, document) do
    state.mongo_api.replace_one(
      state.topology,
      state.collection,
      %{"_id" => profile_id},
      document,
      upsert: true
    )
  rescue
    error ->
      {:error, {:exception, error}}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp safe_find_profiles(state, assignee_candidates) do
    query = assignee_query(assignee_candidates)

    state.mongo_api
    |> apply(:find, [state.topology, state.collection, query, []])
    |> Enum.take(1)
  rescue
    error ->
      {:error, {:exception, error}}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp default_profile(profile_id) do
    now = iso8601_now()

    %{
      "profile_id" => profile_id,
      "user_id" => profile_id,
      "jira" => %{},
      "github" => %{},
      "repository" => %{},
      "recent_sessions" => [],
      "authenticated_at" => nil,
      "updated_at" => now,
      "last_seen_at" => now
    }
  end

  defp normalize_profile(document, profile_id) do
    document
    |> stringify_keys()
    |> Map.delete("_id")
    |> Map.put("profile_id", profile_id)
    |> then(fn profile ->
      default_profile(profile_id)
      |> Map.merge(profile)
      |> Map.put("user_id", profile["user_id"] || profile["client_id"] || profile_id)
      |> Map.update("jira", %{}, &stringify_keys/1)
      |> Map.update("github", %{}, &stringify_keys/1)
      |> Map.update("repository", %{}, &stringify_keys/1)
      |> Map.update("recent_sessions", [], fn sessions ->
        sessions
        |> List.wrap()
        |> Enum.map(&stringify_keys/1)
      end)
    end)
  end

  defp merge_profile(profile, attrs) do
    now = iso8601_now()

    profile
    |> put_if_present("user_id", normalize_string(attrs["user_id"] || attrs[:user_id]))
    |> put_if_present("jira", merge_section(profile["jira"], attrs["jira"] || attrs[:jira], &normalize_jira/1))
    |> put_if_present("github", merge_section(profile["github"], attrs["github"] || attrs[:github], &normalize_github/1))
    |> put_if_present(
      "repository",
      merge_section(profile["repository"], attrs["repository"] || attrs[:repository], &normalize_repository/1)
    )
    |> put_if_present(
      "authenticated_at",
      normalize_string(attrs["authenticated_at"] || attrs[:authenticated_at])
    )
    |> Map.put("updated_at", now)
    |> Map.put("last_seen_at", now)
  end

  defp merge_section(existing, attrs, normalizer) when is_map(attrs) do
    normalized =
      attrs
      |> Enum.map(fn {key, value} -> {to_string(key), normalizer.({to_string(key), value})} end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    existing
    |> stringify_keys()
    |> Map.merge(normalized)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp merge_section(existing, _attrs, _normalizer), do: stringify_keys(existing || %{})

  defp normalize_jira({"base_url", value}), do: normalize_string(value)
  defp normalize_jira({"token", value}), do: normalize_string(value)
  defp normalize_jira({"email", value}), do: normalize_string(value)
  defp normalize_jira({"project_key", value}), do: normalize_string(value)
  defp normalize_jira({"account_id", value}), do: normalize_string(value)
  defp normalize_jira({"display_name", value}), do: normalize_string(value)
  defp normalize_jira({_key, _value}), do: nil

  defp normalize_github({"token", value}), do: normalize_string(value)
  defp normalize_github({"base_url", value}), do: normalize_string(value)
  defp normalize_github({"api_url", value}), do: normalize_string(value)
  defp normalize_github({"login", value}), do: normalize_string(value)
  defp normalize_github({"name", value}), do: normalize_string(value)
  defp normalize_github({"id", value}), do: normalize_string(value)
  defp normalize_github({"html_url", value}), do: normalize_string(value)
  defp normalize_github({"avatar_url", value}), do: normalize_string(value)
  defp normalize_github({_key, _value}), do: nil

  defp normalize_repository({"clone_url", value}), do: normalize_string(value)
  defp normalize_repository({"ref", value}), do: normalize_string(value)
  defp normalize_repository({_key, _value}), do: nil

  defp touch_profile(profile) do
    profile
    |> Map.put("last_seen_at", iso8601_now())
    |> Map.put("updated_at", Map.get(profile, "updated_at", iso8601_now()))
  end

  defp recent_session_from_issue_payload(issue_payload) do
    running = issue_payload[:running] || issue_payload["running"] || %{}
    session_id = map_value(running, :session_id)

    case normalize_string(session_id) do
      nil ->
        {:error, :session_unavailable}

      normalized_session_id ->
        {:ok,
         %{
           "issue_identifier" => map_value(issue_payload, :issue_identifier),
           "issue_id" => map_value(issue_payload, :issue_id),
           "status" => map_value(issue_payload, :status),
           "workspace_path" => workspace_path_from_issue(issue_payload),
           "session_id" => normalized_session_id,
           "thread_id" => map_value(running, :thread_id),
           "turn_id" => map_value(running, :turn_id),
           "turn_count" => map_value(running, :turn_count) || 0,
           "last_event_at" => map_value(running, :last_event_at),
           "captured_at" => iso8601_now()
         }}
    end
  end

  defp workspace_path_from_issue(issue_payload) do
    get_in(issue_payload, [:workspace, :path]) || get_in(issue_payload, ["workspace", "path"])
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp put_recent_session(profile, recent_session, max_recent_sessions) do
    existing_sessions = Map.get(profile, "recent_sessions", [])

    recent_sessions =
      [
        recent_session
        | Enum.reject(existing_sessions, fn existing ->
            existing["session_id"] == recent_session["session_id"] ||
              existing["issue_identifier"] == recent_session["issue_identifier"]
          end)
      ]
      |> Enum.take(max_recent_sessions)

    profile
    |> Map.put("recent_sessions", recent_sessions)
    |> Map.put("updated_at", iso8601_now())
    |> Map.put("last_seen_at", iso8601_now())
  end

  defp public_profile(profile) do
    jira = Map.get(profile, "jira", %{})
    github = Map.get(profile, "github", %{})

    %{
      "profile_id" => profile["profile_id"] || profile["user_id"],
      "user_id" => profile["user_id"] || profile["profile_id"],
      "jira" => %{
        "base_url" => jira["base_url"],
        "email" => jira["email"],
        "project_key" => jira["project_key"],
        "account_id" => jira["account_id"],
        "display_name" => jira["display_name"],
        "has_token" => is_binary(jira["token"]),
        "token_preview" => token_preview(jira["token"])
      },
      "github" => %{
        "base_url" => github["base_url"],
        "api_url" => github["api_url"],
        "login" => github["login"],
        "name" => github["name"],
        "id" => github["id"],
        "html_url" => github["html_url"],
        "avatar_url" => github["avatar_url"],
        "has_token" => is_binary(github["token"]),
        "token_preview" => token_preview(github["token"])
      },
      "repository" => Map.get(profile, "repository", %{}),
      "recent_sessions" => Map.get(profile, "recent_sessions", []),
      "authenticated_at" => profile["authenticated_at"],
      "updated_at" => profile["updated_at"],
      "last_seen_at" => profile["last_seen_at"]
    }
  end

  defp token_preview(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        nil

      String.length(trimmed) <= 4 ->
        String.duplicate("*", String.length(trimmed))

      true ->
        String.duplicate("*", max(String.length(trimmed) - 4, 0)) <> String.slice(trimmed, -4, 4)
    end
  end

  defp token_preview(_value), do: nil

  defp find_cached_profile_by_assignee(clients, assignee_candidates) do
    match_values = MapSet.new(assignee_candidates)

    clients
    |> Map.values()
    |> Enum.find(fn profile ->
      profile
      |> assignee_match_values()
      |> MapSet.intersection(match_values)
      |> MapSet.size() > 0
    end)
  end

  defp assignee_match_values(profile) when is_map(profile) do
    jira = Map.get(profile, "jira", %{})

    [
      jira["account_id"],
      jira["email"],
      jira["display_name"]
    ]
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp issue_assignee_candidates(issue) when is_map(issue) do
    [
      issue[:assignee_id],
      issue["assignee_id"],
      get_in(issue, [:jira, :account_id]),
      get_in(issue, ["jira", "account_id"])
    ]
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp assignee_query([candidate]) do
    %{
      "$or" => [
        %{"jira.account_id" => candidate},
        %{"jira.email" => candidate},
        %{"jira.display_name" => candidate}
      ]
    }
  end

  defp assignee_query(candidates) do
    %{
      "$or" => [
        %{"jira.account_id" => %{"$in" => candidates}},
        %{"jira.email" => %{"$in" => candidates}},
        %{"jira.display_name" => %{"$in" => candidates}}
      ]
    }
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), stringify_keys(nested_value)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp put_if_present(profile, _key, nil), do: profile
  defp put_if_present(profile, key, value), do: Map.put(profile, key, value)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp iso8601_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
