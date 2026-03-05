defmodule SymphonyElixir.TestRunner do
  def run do
    # Ensure memory tracker issues are setup
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %SymphonyElixir.Linear.Issue{
        id: "issue-1",
        identifier: "TEST-1",
        title: "Test Issue",
        state: "Todo"
      }
    ])

    # Start app
    Application.ensure_all_started(:symphony_elixir)

    # Wait for completion (the memory tracker should execute the task locally and finish)
    Process.sleep(2000)

    # Check status
    %{running: running, completed: completed} = :sys.get_state(Process.whereis(SymphonyElixir.Orchestrator))
    IO.puts("Running count: #{map_size(running)}")
    IO.puts("Completed count: #{MapSet.size(completed)}")
  end
end

SymphonyElixir.TestRunner.run()
