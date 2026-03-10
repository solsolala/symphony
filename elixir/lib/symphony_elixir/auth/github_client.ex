defmodule SymphonyElixir.Auth.GitHubClient do
  @moduledoc """
  Verifies GitHub personal access tokens against the authenticated user endpoint.
  """

  @github_api_root "https://api.github.com"

  @type identity :: %{
          id: String.t() | nil,
          login: String.t() | nil,
          name: String.t() | nil,
          html_url: String.t() | nil,
          avatar_url: String.t() | nil
        }

  @spec fetch_identity(String.t()) :: {:ok, identity()} | {:error, term()}
  def fetch_identity(token) when is_binary(token) do
    req =
      Req.new(
        method: :get,
        url: @github_api_root <> "/user",
        headers: [
          {"authorization", "Bearer #{String.trim(token)}"},
          {"accept", "application/vnd.github+json"},
          {"content-type", "application/json"},
          {"user-agent", "symphony-auth"},
          {"x-github-api-version", "2022-11-28"}
        ],
        connect_options: [timeout: 15_000]
      )

    case request_fun().(req) do
      {:ok, %{status: 200, body: body}} ->
        normalize_identity(body)

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :invalid_github_token}

      {:ok, %{status: status}} ->
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp normalize_identity(%{"login" => login} = body) when is_binary(login) do
    {:ok,
     %{
       id: normalize_optional_string(body["id"]),
       login: login,
       name: normalize_optional_string(body["name"]),
       html_url: normalize_optional_string(body["html_url"]),
       avatar_url: normalize_optional_string(body["avatar_url"])
     }}
  end

  defp normalize_identity(body), do: {:error, {:github_invalid_payload, body}}

  defp request_fun do
    Application.get_env(:symphony_elixir, :auth_github_request_fun, &Req.request/1)
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_string(_value), do: nil
end
