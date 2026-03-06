# Symphony Kubernetes(k8s) 환경에서 Codex 실행 여부 확인 가이드

Symphony는 Kubernetes(k8s) 클러스터에서 각 이슈별 독립된 작업공간(workspace)을 만들고, 파드 내부에서 `codex app-server` 프로세스를 실행하여 에이전트 작업을 오케스트레이션합니다.

현재 k8s 환경에 배포된 파드(Pod)당 코덱스가 실제로 정상적으로 돌아가고 있는지 확인하는 방법은 다음과 같습니다.

## 1. 파드(Pod) 상태 및 로그 확인 (`kubectl`)

가장 먼저 오케스트레이터 파드가 정상적으로 떠 있는지와 로그에 문제가 없는지 확인합니다.

```bash
# Symphony 관련 파드 목록 확인 (Helm 라벨 기준)
kubectl get pods -l app.kubernetes.io/name=symphony

# 파드 로그 확인 (에러가 없는지, 세션 시작/종료 로그가 있는지)
kubectl logs <파드-이름>
```

오케스트레이터 로그에서 `session_started`, `turn_completed` 등의 이벤트가 보인다면 코덱스와의 연동이 정상적으로 이루어지고 있는 것입니다.

## 2. 내부 파드에서 코덱스 프로세스 실행 여부 직접 확인

가장 확실한 방법은 파드 내부에 직접 접속하여 `codex` 프로세스가 메모리에 올라와서 실행 중인지 확인하는 것입니다. Symphony는 각 이슈마다 백그라운드로 코덱스 서버를 띄웁니다.

```bash
# 1. 파드 내부에 쉘로 접속
kubectl exec -it <파드-이름> -- sh
# (또는 bash가 설치된 환경이라면 bash 사용)

# 2. 현재 실행 중인 프로세스 목록 중 codex 관련 프로세스가 있는지 확인
ps aux | grep codex
```

정상적으로 이슈가 할당되어 작업 중이라면, 아래와 같이 `codex app-server` 명령어가 실행 중인 프로세스 라인을 볼 수 있습니다. (설정된 `codex.command`에 따라 파라미터가 다를 수 있습니다.)

```text
jules      1234  0.5  1.2  123456  65432 ?        Sl   10:00   0:02 codex --config shell_environment_policy.inherit=all --model gpt-5.3-codex app-server
```

### 작업 공간(Workspace) 확인

Symphony는 설정된 `workspace.root` (기본 `/app/workspaces` 또는 헬름 차트에 설정된 경로) 밑에 각 이슈의 식별자(예: `ABC-123`)로 디렉토리를 생성하여 코덱스를 실행합니다.

```bash
# 파드 내부에서
ls -l /app/workspaces
```

이슈별로 디렉토리가 생성되어 있고, 그 안에 `.codex` 폴더나 관련 소스코드가 클론되어 있다면 정상적으로 워크스페이스가 준비되고 코덱스가 해당 디렉토리를 워킹 디렉토리로 삼고 있다는 뜻입니다.

## 3. 대시보드/API를 통한 세션 실행 상태 모니터링

Symphony는 선택적으로 HTTP 서버(기본 포트 4000)를 제공하여 현재 실행 중인 세션들의 상태를 API로 조회할 수 있습니다. 이를 통해 코덱스가 내부적으로 토큰을 소모하며 턴(turn)을 진행 중인지 확인할 수 있습니다.

```bash
# 1. 로컬 환경으로 포트 포워딩
kubectl port-forward <파드-이름> 4000:4000

# 2. 다른 터미널에서 API 조회
curl -s http://localhost:4000/api/v1/state | jq
```

출력 결과에서 `running` 배열을 확인합니다.
```json
"running": [
  {
    "issue_identifier": "ABC-123",
    "session_id": "thread-1-turn-1",
    "turn_count": 2,
    "last_event": "turn_completed",
    "tokens": {
      "input_tokens": 1200,
      "output_tokens": 800,
      "total_tokens": 2000
    }
  }
]
```
`running` 리스트에 작업 중인 세션이 있고 `tokens` (토큰 수) 및 `last_event` 가 갱신되고 있다면, 백그라운드에서 코덱스가 문제없이 파드 내 자원을 할당받아 연산 중임을 의미합니다.

## 요약

파드 당 코덱스가 돌아가고 있는지 최종 확인하려면:
1. `kubectl get pods`로 파드 상태 확인.
2. `kubectl exec -it <파드-이름> -- sh` 후 `ps aux | grep codex`로 실제 메모리 상 프로세스 존재 유무 확인.
3. `curl http://localhost:4000/api/v1/state`를 통해 오케스트레이터가 코덱스 토큰 및 이벤트를 정상적으로 트래킹하고 있는지 확인.
