defmodule SymphonyElixirWeb.ClientSessionController do
  @moduledoc """
  Authenticated user API for persisting Jira, GitHub, repository, and Codex session metadata.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.BrowserSessionStore
  alias SymphonyElixirWeb.{ClientSessionPlug, CurrentUserPlug, Endpoint, Presenter}

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, _params) do
    with_current_user(conn, fn conn, user_id ->
      profile = BrowserSessionStore.touch(browser_session_store(), user_id)
      json(conn, %{client_id: current_client_id(conn), user_id: user_id, profile: profile})
    end)
  end

  @spec update(Conn.t(), map()) :: Conn.t()
  def update(conn, params) do
    with_current_user(conn, fn conn, user_id ->
      profile = BrowserSessionStore.upsert_profile(browser_session_store(), user_id, params)
      json(conn, %{client_id: current_client_id(conn), user_id: user_id, profile: profile})
    end)
  end

  @spec capture_issue(Conn.t(), map()) :: Conn.t()
  def capture_issue(conn, %{"issue_identifier" => issue_identifier}) do
    with_current_user(conn, fn conn, user_id ->
      issue_identifier
      |> Presenter.issue_payload(orchestrator(), snapshot_timeout_ms())
      |> handle_issue_capture(conn, user_id)
    end)
  end

  defp current_client_id(conn) do
    ClientSessionPlug.client_id(conn)
  end

  defp current_user_id(conn) do
    CurrentUserPlug.user_id(conn)
  end

  defp browser_session_store do
    Application.get_env(:symphony_elixir, :browser_session_store, BrowserSessionStore)
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp handle_issue_capture({:ok, payload}, conn, user_id) do
    case BrowserSessionStore.capture_issue(browser_session_store(), user_id, payload) do
      {:ok, profile} ->
        json(conn, %{client_id: current_client_id(conn), user_id: user_id, profile: profile})

      {:error, :session_unavailable} ->
        error_response(conn, 409, "session_unavailable", "Issue is not running an active Codex session")
    end
  end

  defp handle_issue_capture({:error, :issue_not_found}, conn, _user_id) do
    error_response(conn, 404, "issue_not_found", "Issue not found")
  end

  defp with_current_user(conn, fun) when is_function(fun, 2) do
    case current_user_id(conn) do
      user_id when is_binary(user_id) ->
        fun.(conn, user_id)

      _ ->
        error_response(conn, 401, "authentication_required", "Login with Jira and GitHub tokens first")
    end
  end
end
