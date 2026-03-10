defmodule SymphonyElixir.Auth.JiraClient do
  @moduledoc """
  Verifies Jira personal access tokens against the authenticated user endpoint.
  """

  @type identity :: %{
          base_url: String.t(),
          account_id: String.t() | nil,
          display_name: String.t() | nil,
          email: String.t() | nil
        }

  @spec fetch_identity(String.t(), String.t()) :: {:ok, identity()} | {:error, term()}
  def fetch_identity(base_url, token) when is_binary(base_url) and is_binary(token) do
    with {:ok, normalized_base_url} <- normalize_base_url(base_url),
         {:ok, identity} <- request_identity(normalized_base_url, token, "/rest/api/2/myself") do
      {:ok, identity}
    else
      {:error, {:jira_api_status, 404}} ->
        with {:ok, normalized_base_url} <- normalize_base_url(base_url) do
          request_identity(normalized_base_url, token, "/rest/api/3/myself")
        end

      {:error, {:jira_api_status, status}} when status in [401, 403] ->
        {:error, :invalid_jira_token}

      {:error, :invalid_jira_token} = error ->
        error

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_identity(base_url, token, path) do
    req =
      Req.new(
        method: :get,
        url: base_url <> path,
        headers: [
          {"authorization", "Bearer #{String.trim(token)}"},
          {"accept", "application/json"},
          {"content-type", "application/json"}
        ],
        connect_options: [timeout: 15_000]
      )

    case request_fun().(req) do
      {:ok, %{status: 200, body: body}} ->
        normalize_identity(base_url, body)

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :invalid_jira_token}

      {:ok, %{status: status}} ->
        {:error, {:jira_api_status, status}}

      {:error, reason} ->
        {:error, {:jira_api_request, reason}}
    end
  end

  defp normalize_identity(base_url, body) when is_map(body) do
    account_id =
      normalize_optional_string(body["accountId"]) ||
        normalize_optional_string(body["account_id"]) ||
        normalize_optional_string(body["name"]) ||
        normalize_optional_string(body["key"])

    display_name =
      normalize_optional_string(body["displayName"]) ||
        normalize_optional_string(body["display_name"])

    email =
      normalize_optional_string(body["emailAddress"]) ||
        normalize_optional_string(body["email"])

    if is_binary(account_id) or is_binary(display_name) or is_binary(email) do
      {:ok,
       %{
         base_url: base_url,
         account_id: account_id,
         display_name: display_name,
         email: email
       }}
    else
      {:error, {:jira_invalid_payload, body}}
    end
  end

  defp normalize_base_url(base_url) when is_binary(base_url) do
    trimmed = String.trim(base_url)

    case URI.parse(trimmed) do
      %URI{scheme: scheme, host: host} = uri when scheme in ["http", "https"] and is_binary(host) ->
        normalized_path =
          uri.path
          |> to_string()
          |> String.trim_trailing("/")
          |> String.replace(~r|/rest/api/[23]$|, "")

        normalized_uri = %{uri | path: normalized_path, query: nil, fragment: nil}
        {:ok, normalized_uri |> URI.to_string() |> String.trim_trailing("/")}

      _ ->
        {:error, :invalid_jira_base_url}
    end
  end

  defp request_fun do
    Application.get_env(:symphony_elixir, :auth_jira_request_fun, &Req.request/1)
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil
end
