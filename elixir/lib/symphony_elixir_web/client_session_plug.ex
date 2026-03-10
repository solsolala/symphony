defmodule SymphonyElixirWeb.ClientSessionPlug do
  @moduledoc """
  Ensures every browser session has a stable client identifier.
  """

  import Plug.Conn

  @session_key :client_id

  @spec init(term()) :: term()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case client_id(conn) do
      client_id when is_binary(client_id) ->
        assign(conn, :client_id, client_id)

      _ ->
        client_id = generate_client_id()

        conn
        |> put_session(@session_key, client_id)
        |> assign(:client_id, client_id)
    end
  end

  @spec client_id(Plug.Conn.t()) :: String.t() | nil
  def client_id(conn) do
    conn.assigns[:client_id] || get_session(conn, @session_key) || get_session(conn, to_string(@session_key))
  end

  defp generate_client_id do
    "client-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end
end
