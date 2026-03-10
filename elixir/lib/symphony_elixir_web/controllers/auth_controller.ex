defmodule SymphonyElixirWeb.AuthController do
  @moduledoc """
  Handles token-based login and logout for the observability dashboard.
  """

  use Phoenix.Controller, formats: []

  alias Plug.Conn
  alias SymphonyElixir.Auth
  alias SymphonyElixir.BrowserSessionStore
  alias SymphonyElixirWeb.CurrentUserPlug

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(conn, params) do
    case Auth.authenticate(params) do
      {:ok, %{user_id: user_id, profile_attrs: profile_attrs, summary: summary}} ->
        _profile = BrowserSessionStore.upsert_profile(browser_session_store(), user_id, profile_attrs)

        conn
        |> CurrentUserPlug.put_user_id(user_id)
        |> put_flash(:info, "Signed in as #{summary}.")
        |> redirect(to: "/")

      {:error, reason} ->
        conn
        |> put_flash(:error, Auth.error_message(reason))
        |> redirect(to: "/")
    end
  end

  @spec delete(Conn.t(), map()) :: Conn.t()
  def delete(conn, _params) do
    conn
    |> CurrentUserPlug.clear_user_id()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: "/")
  end

  defp browser_session_store do
    Application.get_env(:symphony_elixir, :browser_session_store, BrowserSessionStore)
  end
end
