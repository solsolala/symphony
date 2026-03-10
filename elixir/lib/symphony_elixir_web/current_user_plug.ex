defmodule SymphonyElixirWeb.CurrentUserPlug do
  @moduledoc """
  Loads and manages the authenticated Symphony user identifier in the browser session.
  """

  import Plug.Conn

  @session_key :user_id

  @spec init(term()) :: term()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    assign(conn, :current_user_id, user_id(conn))
  end

  @spec user_id(Plug.Conn.t()) :: String.t() | nil
  def user_id(conn) do
    conn.assigns[:current_user_id] || get_session(conn, @session_key) || get_session(conn, to_string(@session_key))
  end

  @spec put_user_id(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_user_id(conn, user_id) when is_binary(user_id) do
    conn
    |> configure_session(renew: true)
    |> put_session(@session_key, user_id)
    |> assign(:current_user_id, user_id)
  end

  @spec clear_user_id(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_user_id(conn) do
    conn
    |> configure_session(renew: true)
    |> delete_session(@session_key)
    |> assign(:current_user_id, nil)
  end
end
