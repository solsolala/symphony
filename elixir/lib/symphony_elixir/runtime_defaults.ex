defmodule SymphonyElixir.RuntimeDefaults do
  @moduledoc """
  Resolves deployment defaults from runtime env vars with application config fallback.
  """

  @spec jira_base_url() :: String.t() | nil
  def jira_base_url do
    runtime_value("SYMPHONY_DEFAULT_JIRA_BASE_URL", :default_jira_base_url)
  end

  @spec github_base_url() :: String.t()
  def github_base_url do
    runtime_value("SYMPHONY_DEFAULT_GITHUB_BASE_URL", :default_github_base_url) || "https://github.com"
  end

  defp runtime_value(env_name, app_key) do
    normalize_optional_binary(System.get_env(env_name)) ||
      normalize_optional_binary(Application.get_env(:symphony_elixir, app_key))
  end

  defp normalize_optional_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_binary(_value), do: nil
end
