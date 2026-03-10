defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(SymphonyElixirWeb.ClientSessionPlug)
    plug(SymphonyElixirWeb.CurrentUserPlug)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :client_session_api do
    plug(:fetch_session)
    plug(SymphonyElixirWeb.ClientSessionPlug)
    plug(SymphonyElixirWeb.CurrentUserPlug)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    post("/login", AuthController, :create)
    post("/logout", AuthController, :delete)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:client_session_api)

    get("/api/v1/session", ClientSessionController, :show)
    put("/api/v1/session", ClientSessionController, :update)
    post("/api/v1/session/issues/:issue_identifier/capture", ClientSessionController, :capture_issue)
    match(:*, "/api/v1/session", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/session/issues/:issue_identifier/capture", ObservabilityApiController, :method_not_allowed)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)

    post("/api/v1/internal/update", ObservabilityApiController, :internal_update)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/internal/update", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
