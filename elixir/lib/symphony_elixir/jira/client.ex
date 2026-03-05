defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Jira client for fetching and updating issues.
  """

  alias SymphonyElixir.Config

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    # Placeholder
    {:ok, []}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(_states) do
    # Placeholder
    {:ok, []}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(_issue_ids) do
    # Placeholder
    {:ok, []}
  end
end
