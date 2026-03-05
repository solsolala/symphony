---
tracker:
  kind: memory
workspace:
  root: /tmp/symphony_workspaces
agent:
  max_concurrent_agents: 2
  max_turns: 5
codex:
  command: "echo '{\"method\":\"initialized\",\"params\":{}}' && echo '{\"id\":3,\"method\":\"turn/completed\",\"params\":{\"usage\": {\"total_tokens\": 10}}}' && exit 0"
---

Test Prompt
