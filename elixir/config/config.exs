import Config

config :phoenix, :json_library, Jason

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

config :symphony_elixir,
  mongodb_uri: System.get_env("MONGODB_URI"),
  mongodb_pool_size:
    (case Integer.parse(System.get_env("MONGODB_POOL_SIZE", "5")) do
       {pool_size, ""} when pool_size > 0 -> pool_size
       _ -> 5
     end),
  mongodb_topology: SymphonyElixir.Mongo,
  browser_session_store_collection: System.get_env("SYMPHONY_BROWSER_SESSION_COLLECTION", "user_sessions"),
  default_jira_base_url: System.get_env("SYMPHONY_DEFAULT_JIRA_BASE_URL"),
  default_github_base_url: System.get_env("SYMPHONY_DEFAULT_GITHUB_BASE_URL")
