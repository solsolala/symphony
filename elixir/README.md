# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

> [!NOTE]
> This fork diverges from the OpenAI reference implementation in a few major
> ways: it is Jira-first, includes a user login page for Jira and GitHub
> credentials, persists user session state in MongoDB, and is designed to run
> well in Kubernetes where each ticket can execute in its own worker pod.

## Screenshots

Login page with optional Jira and GitHub base URLs:

![Symphony login page](../.github/media/symphony-login-k3s.png)

Authenticated dashboard example with remembered sessions and runtime state:

![Symphony dashboard example](../.github/media/symphony-dashboard-user-guide.png)

## How it works

1. Polls Jira or another configured tracker for candidate work
2. Optionally serves a Phoenix dashboard at `/`
3. Requires each dashboard user to log in with:
   - Jira token
   - GitHub token
   - optional Jira and GitHub base URLs that can fall back to deployment defaults
4. Persists remembered Codex session metadata and operator profile metadata in
   MongoDB
5. Creates an isolated workspace per issue
6. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/)
   inside the issue workspace or inside a Kubernetes worker pod
7. Keeps Codex working on the issue until the work is done

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## What Changed Compared To The OpenAI Reference Repo

- The default operator workflow is Jira-centered rather than Linear-centered.
- The web UI is not just an observability page anymore; it is also a login page
  for user-scoped Jira and GitHub credentials.
- User profile metadata and remembered Codex sessions are persisted in MongoDB
  instead of browser-only or local-disk state.
- Kubernetes is a first-class deployment target. The orchestrator pod can spawn
  one worker pod per ticket.
- Worker pods can inherit user-scoped Jira and GitHub credentials based on Jira
  assignee matching.
- Internal Jira and GitHub Enterprise URLs are configurable through both
  deployment env vars and the login page.

Current limitation:
- Tracker polling is still driven by deployment-level config such as
  `tracker.endpoint`, `JIRA_API_TOKEN`, and workflow settings.
- User login credentials currently affect dashboard identity, remembered Codex
  sessions, and worker-pod runtime credentials. They do not yet replace the
  deployment-level tracker polling identity.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Decide whether you are running:
   - locally or on a single host
   - in Kubernetes using the chart in
     [charts/symphony/README.md](/Users/chee_mac/symphony/charts/symphony/README.md)
3. Copy this directory's `WORKFLOW.md` to your repo and customize it.
4. For Jira-based runs, prepare:
   - a deployment-level Jira token for tracker polling
   - a Jira base URL for your Jira Cloud or internal Jira server
5. If you will use the dashboard login flow, each user also needs:
   - a personal Jira token
   - a personal GitHub or GitHub Enterprise token
   - optional Jira and GitHub base URLs if they need to override the deployment defaults
6. If you want the dashboard and session APIs, start Symphony with `--port`.
7. If you want Kubernetes worker pods, follow the chart guide instead of only
   using the local runtime instructions below.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: jira
  endpoint: https://jira.company.internal
  api_key: $JIRA_API_TOKEN
  project_slug: "PLATFORM"
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.company.internal/your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Jira issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- Supported `codex.turn_sandbox_policy.type` values: `dangerFullAccess`, `readOnly`,
  `externalSandbox`, `workspaceWrite`.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `JIRA_API_TOKEN` when unset or when value is
  `$JIRA_API_TOKEN`.
- `tracker.endpoint` can point at Jira Cloud or an internal Jira server.
- `JIRA_BASE_URL` is used as a runtime override for Jira endpoint resolution.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  endpoint: $JIRA_BASE_URL
  api_key: $JIRA_API_TOKEN
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN app-server --model gpt-5.3-codex"
```

- If `WORKFLOW.md` is missing or has invalid YAML, startup and scheduling are halted until fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack and also acts as the
operator login page:

- LiveView for the dashboard and login page at `/`
- Login requires:
  - Jira base URL
  - Jira token
  - GitHub or GitHub Enterprise base URL
  - GitHub token
- JSON API for operational debugging under `/api/v1/*`
- MongoDB-backed persistence for user profile metadata and remembered Codex
  sessions
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

`/api/v1/session` is intended for authenticated dashboard users. It returns the
current user profile and remembered session state after login.

## Permission Model

This fork has two credential layers:

1. Deployment-level credentials
   - used by tracker polling and general service startup
   - examples: `JIRA_API_TOKEN`, `JIRA_BASE_URL`, `OPENAI_API_KEY`
2. User-level credentials from the login page
   - used for dashboard identity and remembered session persistence
   - passed to worker pods when the issue assignee matches a stored Jira user
   - include Jira and GitHub or GitHub Enterprise base URLs and tokens

Worker pod behavior:

- If a running issue's Jira assignee matches a stored user profile, the worker
  pod receives that user's `JIRA_BASE_URL`, `JIRA_API_TOKEN`, `GITHUB_TOKEN`,
  `GH_TOKEN`, `GITHUB_SERVER_URL`, and `GITHUB_API_URL`.
- If no user match is found, the worker falls back to deployment-level env vars.

## Kubernetes

For Kubernetes deployment, do not rely on this file alone. Use
[charts/symphony/README.md](/Users/chee_mac/symphony/charts/symphony/README.md)
for:

- worker-pod image and env wiring
- MongoDB setup
- login-page defaults for internal Jira and GitHub servers
- Helm values for Jira polling and private repository clone behavior

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
