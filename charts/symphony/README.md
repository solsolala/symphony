# Symphony Helm Chart

This chart runs one Symphony orchestrator pod and lets that orchestrator create one worker pod per ticket.

## What This Chart Configures

- `tracker.*` selects the ticket source.
- `tracker.endpoint` lets you point Symphony at Jira Cloud or an internal Jira base URL.
- `repository.cloneUrl` and `repository.ref` control which repo each ticket workspace clones.
- `codex.command` controls how worker pods launch Codex. The default is `codex app-server`.
- `env` injects runtime credentials into the orchestrator pod.
- `worker.inheritEnv` controls which env vars worker pods receive from the orchestrator pod.

Real Codex turns need `OPENAI_API_KEY` in `env` so the worker pod inherits it before launching `codex app-server`.

## Prerequisites

- Kubernetes cluster with outbound access to OpenAI and your Git host
- Helm 3
- A pushed Symphony image built from `/Users/chee_mac/symphony/Dockerfile`
- `OPENAI_API_KEY`
- `JIRA_API_TOKEN`

## 1. Build And Push The Image

```bash
docker build -t registry.example.com/symphony:0.1.0 /Users/chee_mac/symphony
docker push registry.example.com/symphony:0.1.0
```

The same image is used for the orchestrator pod and the per-ticket worker pods.

## 2. Create Namespace And Secrets

```bash
kubectl create namespace symphony

kubectl -n symphony create secret generic symphony-openai \
  --from-literal=api-key="$OPENAI_API_KEY"

kubectl -n symphony create secret generic symphony-jira \
  --from-literal=api-key="$JIRA_API_TOKEN"
```

Each deployed Symphony instance uses the Jira token you inject here. The token is not baked into the image or chart.

If you pull from a private registry, create an image pull secret too and reference it from `imagePullSecrets`.

## 3. Create A Values File

Create `values-prod.yaml`:

```yaml
image:
  repository: registry.example.com/symphony
  tag: "0.1.0"
  pullPolicy: IfNotPresent

worker:
  image:
    repository: registry.example.com/symphony
    tag: "0.1.0"
    pullPolicy: IfNotPresent

tracker:
  kind: jira
  endpoint: https://jira.company.internal
  projectSlug: PLATFORM
  apiKeyEnv: JIRA_API_TOKEN

repository:
  cloneUrl: https://github.com/your-org/your-repo.git
  ref: main

runtimeServer:
  host: "0.0.0.0"
  port: 4000

env:
  - name: PORT
    value: "4000"
  - name: JIRA_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: symphony-jira
        key: api-key
  - name: OPENAI_API_KEY
    valueFrom:
      secretKeyRef:
        name: symphony-openai
        key: api-key
```

Notes:

- `tracker.endpoint` should point at your Jira base URL. For Jira Cloud that is typically `https://your-domain.atlassian.net`; for internal Jira it can be something like `https://jira.company.internal`.
- `worker.inheritEnv` already includes `JIRA_API_TOKEN`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`, and `OPENAI_ORG_ID`.
- If you change `tracker.apiKeyEnv`, make sure the matching env var is present in `env`.
- If workers need extra credentials, add the env var to both `env` and `worker.inheritEnv`.

## 4. Install Or Upgrade

```bash
helm upgrade --install symphony /Users/chee_mac/symphony/charts/symphony \
  --namespace symphony \
  --create-namespace \
  -f values-prod.yaml
```

## 5. Verify The Deployment

Check the orchestrator pod:

```bash
kubectl -n symphony get pods
kubectl -n symphony logs deploy/symphony -f
```

Check the dashboard and JSON API:

```bash
kubectl -n symphony port-forward deploy/symphony 4000:4000
curl http://127.0.0.1:4000/api/v1/state
```

Worker pods appear only when the Jira tracker returns an active issue:

```bash
kubectl -n symphony get pods -w
```

## Infra-Only Smoke Test

If you only want to validate Kubernetes wiring without depending on Jira data, deploy the same chart with `tracker.kind=memory` and keep the same `OPENAI_API_KEY` and repo settings. That validates the orchestrator pod, worker pod image, and real Codex execution path independently from Jira.
