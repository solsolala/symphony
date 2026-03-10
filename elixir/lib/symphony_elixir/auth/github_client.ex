defmodule SymphonyElixir.Auth.GitHubClient do
  @moduledoc """
  Verifies GitHub personal access tokens against the authenticated user endpoint.
  """

  @type identity :: %{
          base_url: String.t(),
          api_url: String.t(),
          id: String.t() | nil,
          login: String.t() | nil,
          name: String.t() | nil,
          html_url: String.t() | nil,
          avatar_url: String.t() | nil
        }

  @spec fetch_identity(String.t(), String.t()) :: {:ok, identity()} | {:error, term()}
  def fetch_identity(base_url, token) when is_binary(base_url) and is_binary(token) do
    with {:ok, %{base_url: normalized_base_url, api_url: api_url}} <- normalize_base_url(base_url) do
      req =
        Req.new(
          method: :get,
          url: api_url <> "/user",
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
          normalize_identity(body, normalized_base_url, api_url)

        {:ok, %{status: status}} when status in [401, 403] ->
          {:error, :invalid_github_token}

        {:ok, %{status: status}} ->
          {:error, {:github_api_status, status}}

        {:error, reason} ->
          {:error, {:github_api_request, reason}}
      end
    end
  end

  defp normalize_identity(%{"login" => login} = body, base_url, api_url) when is_binary(login) do
    {:ok,
     %{
       base_url: base_url,
       api_url: api_url,
       id: normalize_optional_string(body["id"]),
       login: login,
       name: normalize_optional_string(body["name"]),
       html_url: normalize_optional_string(body["html_url"]),
       avatar_url: normalize_optional_string(body["avatar_url"])
     }}
  end

  defp normalize_identity(body, _base_url, _api_url), do: {:error, {:github_invalid_payload, body}}

  defp normalize_base_url(base_url) when is_binary(base_url) do
    trimmed = String.trim(base_url)

    case URI.parse(trimmed) do
      %URI{scheme: scheme, host: host, path: path} = uri when scheme in ["http", "https"] and is_binary(host) ->
        normalized_path = path |> to_string() |> String.trim_trailing("/")

        cond do
          host == "github.com" or host == "api.github.com" ->
            {:ok, %{base_url: "https://github.com", api_url: "https://api.github.com"}}

          String.ends_with?(normalized_path, "/api/v3") ->
            web_path = String.replace_suffix(normalized_path, "/api/v3", "")

            {:ok,
             %{
               base_url: %{uri | path: web_path, query: nil, fragment: nil} |> URI.to_string() |> String.trim_trailing("/"),
               api_url: %{uri | path: normalized_path, query: nil, fragment: nil} |> URI.to_string() |> String.trim_trailing("/")
             }}

          true ->
            normalized_uri = %{uri | path: normalized_path, query: nil, fragment: nil}
            web_base_url = normalized_uri |> URI.to_string() |> String.trim_trailing("/")

            {:ok, %{base_url: web_base_url, api_url: web_base_url <> "/api/v3"}}
        end

      _ ->
        {:error, :invalid_github_base_url}
    end
  end

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
