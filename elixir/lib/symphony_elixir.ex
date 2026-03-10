defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    children =
      [
        {Phoenix.PubSub, name: SymphonyElixir.PubSub},
        {Task.Supervisor, name: SymphonyElixir.TaskSupervisor}
      ] ++
        mongo_children() ++
        [
          SymphonyElixir.BrowserSessionStore,
          SymphonyElixir.WorkflowStore,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard
        ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  defp mongo_children do
    case mongo_uri() do
      uri when is_binary(uri) and uri != "" ->
        [
          {Mongo,
           [
             name: Application.get_env(:symphony_elixir, :mongodb_topology, SymphonyElixir.Mongo),
             url: uri,
             pool_size: Application.get_env(:symphony_elixir, :mongodb_pool_size, 5)
           ]}
        ]

      _ ->
        []
    end
  end

  defp mongo_uri do
    case Application.get_env(:symphony_elixir, :mongodb_uri) do
      uri when is_binary(uri) ->
        case String.trim(uri) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end
end
