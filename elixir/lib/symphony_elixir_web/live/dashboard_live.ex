defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.BrowserSessionStore
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, session, socket) do
    client_id = session["client_id"]
    user_id = session["user_id"]

    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:client_id, client_id)
      |> assign(:user_id, user_id)
      |> assign(:authenticated?, is_binary(user_id))
      |> assign(:user_profile, load_user_profile(user_id))
      |> assign(:default_jira_base_url, default_jira_base_url())
      |> assign(:default_github_base_url, default_github_base_url())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:user_profile, load_user_profile(socket.assigns.user_id))
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("remember_session", %{"issue_identifier" => issue_identifier}, socket) do
    socket =
      case maybe_capture_issue_session(socket.assigns.user_id, issue_identifier) do
        {:ok, profile} ->
          assign(socket, :user_profile, profile)

        {:error, _reason} ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @flash["error"] do %>
        <section class="error-card">
          <h2 class="error-title">
            Login failed
          </h2>
          <p class="error-copy"><%= @flash["error"] %></p>
        </section>
      <% end %>

      <%= if @flash["info"] do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Status</h2>
            </div>
          </div>
          <p class="section-copy"><%= @flash["info"] %></p>
        </section>
      <% end %>

      <%= if not @authenticated? do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Token Login</h2>
              <p class="section-copy">
                Enter both tokens to open the Symphony dashboard. The Jira URL can be prefilled from deployment settings and the verified credentials are stored in MongoDB for this Symphony user profile.
              </p>
            </div>
          </div>

          <form method="post" action="/login" class="detail-stack">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />

            <label class="detail-stack">
              <span class="mono">Jira Base URL</span>
              <input
                type="url"
                name="jira_base_url"
                value={@default_jira_base_url || ""}
                placeholder="https://jira.company.internal"
                required
              />
            </label>

            <label class="detail-stack">
              <span class="mono">GitHub Base URL</span>
              <input
                type="url"
                name="github_base_url"
                value={@default_github_base_url || "https://github.com"}
                placeholder="https://github.company.internal"
                required
              />
            </label>

            <label class="detail-stack">
              <span class="mono">Jira Token</span>
              <input type="password" name="jira_token" autocomplete="off" required />
            </label>

            <label class="detail-stack">
              <span class="mono">GitHub Token</span>
              <input type="password" name="github_token" autocomplete="off" required />
            </label>

            <div class="issue-stack">
              <button type="submit" class="subtle-button">Sign In</button>
            </div>
          </form>
        </section>
      <% else %>
      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Operator Profile</h2>
              <p class="section-copy">Per-user Jira, GitHub, repository settings, and remembered Codex sessions stored on this Symphony server.</p>
            </div>
            <form method="post" action="/logout">
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <button type="submit" class="subtle-button">Sign Out</button>
            </form>
          </div>

          <div class="detail-stack">
            <span class="mono">User ID: <%= @user_id || "n/a" %></span>
            <span class="muted">
              GitHub:
              <%= profile_value(@user_profile, ["github", "login"]) || profile_value(@user_profile, ["github", "name"]) || "n/a" %>
            </span>
            <span class="muted">
              GitHub URL:
              <%= profile_value(@user_profile, ["github", "base_url"]) || "n/a" %>
            </span>
            <span class="muted">
              Stored GitHub token:
              <%= token_status(@user_profile, "github") %>
            </span>
            <span class="muted">
              Jira URL:
              <%= profile_value(@user_profile, ["jira", "base_url"]) || "n/a" %>
            </span>
            <span class="muted">
              Stored Jira token:
              <%= token_status(@user_profile, "jira") %>
            </span>
          </div>

          <%= if recent_sessions(@user_profile) == [] do %>
            <p class="empty-state">No remembered sessions for this user yet.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Session</th>
                    <th>Thread</th>
                    <th>Workspace</th>
                    <th>Captured at</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- recent_sessions(@user_profile)}>
                    <td><%= entry["issue_identifier"] || "n/a" %></td>
                    <td class="mono"><%= entry["session_id"] || "n/a" %></td>
                    <td class="mono"><%= entry["thread_id"] || "n/a" %></td>
                    <td class="mono"><%= entry["workspace_path"] || "n/a" %></td>
                    <td class="mono"><%= entry["captured_at"] || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <%= if Map.get(entry, :worker_github_login) || Map.get(entry, :worker_user_id) do %>
                          <span class="muted">
                            owner: <%= Map.get(entry, :worker_github_login) || Map.get(entry, :worker_user_id) %>
                          </span>
                        <% end %>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="remember_session"
                          phx-value-issue_identifier={entry.issue_identifier}
                        >
                          Remember
                        </button>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp load_user_profile(nil), do: nil

  defp load_user_profile(user_id) when is_binary(user_id) do
    BrowserSessionStore.fetch_profile(browser_session_store(), user_id)
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp browser_session_store do
    Application.get_env(:symphony_elixir, :browser_session_store, BrowserSessionStore)
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp default_jira_base_url do
    Application.get_env(:symphony_elixir, :default_jira_base_url)
  end

  defp default_github_base_url do
    Application.get_env(:symphony_elixir, :default_github_base_url)
  end

  defp maybe_capture_issue_session(nil, _issue_identifier), do: {:error, :missing_user_id}

  defp maybe_capture_issue_session(user_id, issue_identifier) do
    with {:ok, payload} <- Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      BrowserSessionStore.capture_issue(browser_session_store(), user_id, payload)
    end
  end

  defp profile_value(nil, _path), do: nil
  defp profile_value(profile, path), do: get_in(profile, path)

  defp token_status(profile, provider) do
    if profile_value(profile, [provider, "has_token"]) do
      profile_value(profile, [provider, "token_preview"]) || "stored"
    else
      "not stored"
    end
  end

  defp recent_sessions(nil), do: []
  defp recent_sessions(profile), do: Map.get(profile, "recent_sessions", [])

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
