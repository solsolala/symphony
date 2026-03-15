# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

This repository is a Jira-first, Kubernetes-oriented fork of the OpenAI
reference Symphony repo. The main additions in this fork are a user login page,
MongoDB-backed user session storage, Jira and GitHub Enterprise support, and
worker-pod credential injection for per-ticket Codex runs.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_The original demo in [this video](.github/media/symphony-demo.mp4) shows the
OpenAI reference flow around Linear. This fork keeps the same high-level idea,
but the implementation here is centered on Jira, GitHub, Kubernetes worker
pods, and an authenticated dashboard._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## What Changed In This Fork

- Jira-first tracker support and deployment guidance instead of Linear-first
  local setup.
- A Phoenix login page at `/` where each operator enters:
  - Jira token
  - GitHub token
  - Optional Jira and GitHub base URLs that fall back to deployment defaults
- MongoDB-backed user session persistence for remembered Codex sessions and
  operator profile metadata.
- Kubernetes deployment flow where one orchestrator pod creates one worker pod
  per ticket.
- Worker pods can receive user-scoped Jira and GitHub credentials when the Jira
  assignee matches a stored operator profile.
- Internal Jira and GitHub Enterprise URLs are configurable both in the login
  UI and in Kubernetes deployment values.

Current caveat:
- The orchestrator's tracker polling path is still driven by deployment-level
  config such as `tracker.*`, `JIRA_API_TOKEN`, and `tracker.endpoint`.
- Per-user login credentials are currently used for dashboard identity,
  remembered Codex sessions, and worker-pod credential injection when assignee
  matching succeeds.

## Docs In This Fork

- [elixir/README.md](/Users/chee_mac/symphony/elixir/README.md)
  Local runtime details, dashboard behavior, config model, and permission model
- [charts/symphony/README.md](/Users/chee_mac/symphony/charts/symphony/README.md)
  Kubernetes deployment guide, login flow, secrets, Jira/GitHub Enterprise
  settings, and worker-pod credential propagation
- [SPEC.md](/Users/chee_mac/symphony/SPEC.md)
  Original Symphony spec
- [openai/symphony](https://github.com/openai/symphony)
  Upstream reference repository

## Running Symphony

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/).

Two practical entry points in this fork are:

- Local/runtime evaluation:
  See [elixir/README.md](/Users/chee_mac/symphony/elixir/README.md)
- Kubernetes deployment:
  See [charts/symphony/README.md](/Users/chee_mac/symphony/charts/symphony/README.md)

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
