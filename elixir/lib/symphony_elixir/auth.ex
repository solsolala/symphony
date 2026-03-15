defmodule SymphonyElixir.Auth do
  @moduledoc """
  Verifies user-supplied Jira and GitHub tokens and derives a stable Symphony user id.
  """

  alias SymphonyElixir.Auth.{GitHubClient, JiraClient}
  alias SymphonyElixir.RuntimeDefaults

  @type login_result :: %{
          user_id: String.t(),
          profile_attrs: map(),
          summary: String.t()
        }

  @spec authenticate(map()) :: {:ok, login_result()} | {:error, term()}
  def authenticate(params) when is_map(params) do
    with {:ok, jira_base_url} <- jira_base_url(params),
         {:ok, jira_token} <- required_string(params, ["jira_token", :jira_token], :missing_jira_token),
         {:ok, github_base_url} <- github_base_url(params),
         {:ok, github_token} <- required_string(params, ["github_token", :github_token], :missing_github_token),
         {:ok, jira_identity} <- JiraClient.fetch_identity(jira_base_url, jira_token),
         {:ok, github_identity} <- GitHubClient.fetch_identity(github_base_url, github_token) do
      user_id = build_user_id(jira_identity, github_identity)

      {:ok,
       %{
         user_id: user_id,
         profile_attrs: %{
           "user_id" => user_id,
           "authenticated_at" => iso8601_now(),
           "jira" => %{
             "base_url" => jira_identity.base_url,
             "token" => jira_token,
             "email" => jira_identity.email,
             "account_id" => jira_identity.account_id,
             "display_name" => jira_identity.display_name
           },
           "github" => %{
             "token" => github_token,
             "base_url" => github_identity.base_url,
             "api_url" => github_identity.api_url,
             "login" => github_identity.login,
             "name" => github_identity.name,
             "id" => github_identity.id,
             "html_url" => github_identity.html_url,
             "avatar_url" => github_identity.avatar_url
           }
         },
         summary: login_summary(jira_identity, github_identity)
       }}
    end
  end

  @spec error_message(term()) :: String.t()
  def error_message(:missing_jira_base_url), do: "Jira base URL is required unless the server has a default configured."
  def error_message(:missing_jira_token), do: "Jira token is required."

  def error_message(:missing_github_base_url),
    do: "GitHub base URL is required unless the server has a default configured."

  def error_message(:missing_github_token), do: "GitHub token is required."
  def error_message(:invalid_jira_base_url), do: "Jira base URL must be a valid http or https URL."
  def error_message(:invalid_github_base_url), do: "GitHub base URL must be a valid GitHub or GitHub Enterprise URL."
  def error_message(:invalid_jira_token), do: "Jira token could not be verified."
  def error_message(:invalid_github_token), do: "GitHub token could not be verified."
  def error_message({:jira_api_status, status}), do: "Jira authentication failed with status #{status}."
  def error_message({:github_api_status, status}), do: "GitHub authentication failed with status #{status}."
  def error_message({:jira_api_request, _reason}), do: "Jira authentication request failed."
  def error_message({:github_api_request, _reason}), do: "GitHub authentication request failed."
  def error_message({:jira_invalid_payload, _payload}), do: "Jira identity payload was incomplete."
  def error_message({:github_invalid_payload, _payload}), do: "GitHub identity payload was incomplete."
  def error_message(_reason), do: "Authentication failed."

  defp required_string(params, keys, error_reason) do
    value =
      Enum.find_value(keys, fn key ->
        case Map.get(params, key) do
          value when is_binary(value) -> String.trim(value)
          _ -> nil
        end
      end)

    case value do
      nil -> {:error, error_reason}
      "" -> {:error, error_reason}
      trimmed -> {:ok, trimmed}
    end
  end

  defp jira_base_url(params) do
    case optional_string(params, ["jira_base_url", :jira_base_url]) || default_jira_base_url() do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, :missing_jira_base_url}
    end
  end

  defp github_base_url(params) do
    case optional_string(params, ["github_base_url", :github_base_url]) || default_github_base_url() do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, :missing_github_base_url}
    end
  end

  defp optional_string(params, keys) do
    keys
    |> Enum.find_value(&(params |> Map.get(&1) |> normalize_optional_string()))
  end

  defp default_jira_base_url do
    RuntimeDefaults.jira_base_url()
  end

  defp default_github_base_url do
    RuntimeDefaults.github_base_url()
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp build_user_id(jira_identity, github_identity) do
    jira_key =
      [jira_identity.base_url, jira_identity.account_id || jira_identity.email || jira_identity.display_name]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(":")

    github_key = github_identity.id || github_identity.login

    "user-" <>
      (:crypto.hash(:sha256, jira_key <> "|" <> github_key)
       |> Base.url_encode64(padding: false)
       |> binary_part(0, 24))
  end

  defp login_summary(jira_identity, github_identity) do
    github_name = github_identity.login || github_identity.name || "GitHub user"
    jira_name = jira_identity.display_name || jira_identity.email || jira_identity.account_id || "Jira user"
    "#{github_name} / #{jira_name}"
  end

  defp iso8601_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
