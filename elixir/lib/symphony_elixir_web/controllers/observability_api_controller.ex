defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec internal_update(Conn.t(), map()) :: Conn.t()
  def internal_update(conn, %{"issue_id" => issue_id, "update" => update}) do
    # When keys are strings because of JSON decoding, we convert them safely to atoms
    update = convert_keys_to_existing_atoms(update)

    # We also need to map "event" value to an atom if it's a string safely
    update =
      if is_binary(update[:event]) do
        try do
          %{update | event: String.to_existing_atom(update[:event])}
        rescue
          ArgumentError -> update
        end
      else
        update
      end

    if Process.whereis(orchestrator()) do
      send(orchestrator(), {:codex_worker_update, issue_id, update})
    end

    json(conn, %{status: "ok"})
  end

  defp convert_keys_to_existing_atoms(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        atom_key =
          try do
            String.to_existing_atom(k)
          rescue
            ArgumentError -> k
          end

        {atom_key, convert_keys_to_existing_atoms(v)}

      {k, v} ->
        {k, convert_keys_to_existing_atoms(v)}
    end)
  end

  defp convert_keys_to_existing_atoms(list) when is_list(list),
    do: Enum.map(list, &convert_keys_to_existing_atoms/1)

  defp convert_keys_to_existing_atoms(other), do: other

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
