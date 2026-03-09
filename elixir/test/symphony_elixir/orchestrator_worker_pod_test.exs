defmodule SymphonyElixir.OrchestratorWorkerPodTest do
  use SymphonyElixir.TestSupport

  test "worker pod manifest includes workflow mount and inherited runtime settings" do
    issue = %Issue{id: "issue-1", identifier: "MT-1"}

    previous_env =
      for key <- [
            "WORKSPACE_ROOT",
            "WORKER_IMAGE",
            "WORKER_IMAGE_PULL_POLICY",
            "WORKER_SERVICE_ACCOUNT_NAME",
            "WORKFLOW_CONFIGMAP_NAME",
            "WORKFLOW_CONFIGMAP_KEY",
            "WORKFLOW_FILE_PATH",
            "WORKER_INHERIT_ENV",
            "WORKER_RESOURCES_JSON",
            "WORKER_NODE_SELECTOR_JSON",
            "WORKER_TOLERATIONS_JSON",
            "WORKER_AFFINITY_JSON",
            "WORKER_IMAGE_PULL_SECRETS_JSON",
            "LINEAR_API_KEY",
            "JIRA_API_TOKEN",
            "OPENAI_API_KEY"
          ],
          into: %{} do
        {key, System.get_env(key)}
      end

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
    end)

    System.put_env("WORKSPACE_ROOT", "/tmp/symphony-workspaces")
    System.put_env("WORKER_IMAGE", "registry.example/symphony-worker:sha-123")
    System.put_env("WORKER_IMAGE_PULL_POLICY", "Always")
    System.put_env("WORKER_SERVICE_ACCOUNT_NAME", "symphony-orchestrator")
    System.put_env("WORKFLOW_CONFIGMAP_NAME", "symphony-config")
    System.put_env("WORKFLOW_CONFIGMAP_KEY", "WORKFLOW.md")
    System.put_env("WORKFLOW_FILE_PATH", "/app/WORKFLOW.md")
    System.put_env("WORKER_INHERIT_ENV", "LINEAR_API_KEY,JIRA_API_TOKEN,OPENAI_API_KEY")
    System.put_env("WORKER_RESOURCES_JSON", ~s({"limits":{"cpu":"1","memory":"1Gi"}}))
    System.put_env("WORKER_NODE_SELECTOR_JSON", ~s({"kubernetes.io/os":"linux"}))
    System.put_env("WORKER_TOLERATIONS_JSON", ~s([{"key":"dedicated","operator":"Exists"}]))
    System.put_env("WORKER_AFFINITY_JSON", ~s({"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{}}}))
    System.put_env("WORKER_IMAGE_PULL_SECRETS_JSON", ~s([{"name":"regcred"}]))
    System.put_env("LINEAR_API_KEY", "linear-token")
    System.put_env("JIRA_API_TOKEN", "jira-token")
    System.put_env("OPENAI_API_KEY", "openai-token")

    manifest =
      Orchestrator.build_worker_pod_manifest_for_test(
        issue,
        "http://10.0.0.12:4000"
      )

    assert get_in(manifest, ["metadata", "name"]) == "symphony-worker-test"
    assert get_in(manifest, ["spec", "serviceAccountName"]) == "symphony-orchestrator"
    assert get_in(manifest, ["spec", "imagePullSecrets"]) == [%{"name" => "regcred"}]
    assert get_in(manifest, ["spec", "nodeSelector"]) == %{"kubernetes.io/os" => "linux"}
    assert get_in(manifest, ["spec", "tolerations"]) == [%{"key" => "dedicated", "operator" => "Exists"}]
    assert get_in(manifest, ["spec", "affinity"]) == %{"nodeAffinity" => %{"requiredDuringSchedulingIgnoredDuringExecution" => %{}}}

    container = get_in(manifest, ["spec", "containers"]) |> List.first()

    assert container["image"] == "registry.example/symphony-worker:sha-123"
    assert container["imagePullPolicy"] == "Always"
    assert container["command"] == ["symphony"]

    assert container["args"] == [
             "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
             "--run-agent",
             "issue-1",
             "--orchestrator-url",
             "http://10.0.0.12:4000",
             "/app/WORKFLOW.md"
           ]

    assert container["resources"] == %{"limits" => %{"cpu" => "1", "memory" => "1Gi"}}
    assert container["volumeMounts"] == [%{"mountPath" => "/app/WORKFLOW.md", "name" => "workflow", "subPath" => "WORKFLOW.md"}]

    env_by_name = Map.new(container["env"], &{&1["name"], &1["value"]})

    assert env_by_name["WORKSPACE_ROOT"] == "/tmp/symphony-workspaces"
    assert env_by_name["LINEAR_API_KEY"] == "linear-token"
    assert env_by_name["JIRA_API_TOKEN"] == "jira-token"
    assert env_by_name["OPENAI_API_KEY"] == "openai-token"

    assert get_in(manifest, ["spec", "volumes"]) == [
             %{"configMap" => %{"name" => "symphony-config"}, "name" => "workflow"}
           ]
  end
end
