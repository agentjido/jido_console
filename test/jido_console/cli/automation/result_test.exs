defmodule Jido.Console.Automation.ResultTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Automation.{Contract, Result}
  alias Jidoka.ExecutionEnvironment
  alias Jidoka.ExecutionEnvironment.AdapterCapabilities
  alias Jidoka.ExecutionEnvironment.Binding
  alias Jidoka.ExecutionEnvironment.Checkpoint
  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.Registration
  alias Jidoka.ExecutionEnvironment.SecurityProfile
  alias Jidoka.Session.Environment

  @profile_digest "sha256:" <> String.duplicate("a", 64)
  @image_digest "sha256:" <> String.duplicate("b", 64)

  test "builds the result envelope and normalizes errors" do
    result =
      Result.new(cell(),
        execution: execution(:error),
        error: Result.error(:failed)
      )

    assert result.schema == "jido.case-result"
    assert result.schema_version == 1
    assert result.turns == []
    assert result.usage == %{}
    assert result.evaluation.status == :not_run
    assert is_binary(result.error.message)
    assert result.execution_environment == %{status: :not_requested}

    assert result.capability_replay == %{
             mode: :live,
             status: :not_replayed,
             recorded_evidence: false,
             matched_calls: 0,
             total_calls: 0
           }
  end

  test "keeps requested, resolved, and confirmed environment facts separate" do
    resolved = resolved_environment()
    environment = completed_environment(resolved)
    cell = Map.put(cell(), :execution_environment, resolved)

    result =
      Result.new(cell,
        execution: execution(:ok),
        environment: environment
      )

    assert result.execution_environment.status == :closed
    assert result.execution_environment.requested.profile_id == "restricted"
    assert result.execution_environment.requested.capability_ids == ["tools.shell"]
    assert result.execution_environment.requested.policy_digest =~ "sha256:"
    assert result.execution_environment.resolved.profile_digest == @profile_digest
    assert result.execution_environment.binding.revision == 1
    assert result.execution_environment.confirmed.status == :confirmed
    assert result.execution_environment.confirmed.backend == "test-backend"
    assert result.execution_environment.confirmed.isolation == :container
    assert result.execution_environment.confirmed.network == :disabled
    assert result.execution_environment.confirmed.workspace == :ephemeral
    assert result.execution_environment.confirmed.image_digest == @image_digest
    assert result.execution_environment.confirmed.applied_limits == %{"memory_mb" => 256}

    assert result.execution_environment.confirmed.checkpoint == %{
             "forkable" => false,
             "supported" => true
           }

    assert result.execution_environment.lifecycle.checkpoint == :confirmed
    assert result.execution_environment.lifecycle.close == :confirmed
    assert result.execution_environment.lifecycle.cleanup == :confirmed

    encoded = Jason.encode!(result)
    refute encoded =~ "secret-marker"
    refute encoded =~ "/private/host/path"
    refute encoded =~ "resource-private"
    refute encoded =~ inspect(__MODULE__)
  end

  test "marks a missing trusted policy as rejected without confirmed facts" do
    cell = Map.put(cell(), :execution_environment, resolved_environment())

    result =
      Result.new(cell,
        execution: execution(:error),
        environment_error: :missing_execution_environment_policy,
        error: Result.error(:missing_execution_environment_policy)
      )

    assert result.execution_environment.status == :rejected
    assert result.execution_environment.requested.profile_id == "restricted"
    assert result.execution_environment.resolved.profile_digest == @profile_digest
    refute Map.has_key?(result.execution_environment, :confirmed)
    refute Map.has_key?(result.execution_environment, :binding)
  end

  test "validates JSON round trips and ignores future optional reader fields" do
    result = valid_result()
    decoded = result |> Jason.encode!() |> Jason.decode!() |> Map.put("future_field", true)

    assert {:ok, read} = Contract.read_case_result(decoded)
    assert read.schema == "jido.case-result"
    refute Map.has_key?(read, :future_field)

    assert {:error, {:invalid_automation_contract, :case_result, _errors}} =
             Contract.validate_case_result(decoded)
  end

  test "accepts only namespaced extension identifiers" do
    valid = Map.put(valid_result(), :extensions, %{"acme.metrics" => %{"score" => 1}})
    assert {:ok, _result} = Contract.validate_case_result(valid)

    invalid = Map.put(valid_result(), :extensions, %{"metrics" => %{}})

    assert {:error, {:invalid_automation_contract, :case_result, _errors}} =
             Contract.validate_case_result(invalid)
  end

  test "rejects nonportable error values and map keys" do
    port = Port.open({:spawn, "true"}, [])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    values = [fn -> :ok end, self(), port, make_ref(), %{1 => "bad key"}]

    for value <- values do
      invalid = put_in(valid_result(), [:error, :details], value)

      assert {:error, {:invalid_automation_contract, :case_result, _reason}} =
               Contract.validate_case_result(invalid)
    end
  end

  test "exposes every reusable contract schema" do
    functions = [
      :case_result_schema,
      :manifest_schema,
      :summary_schema,
      :lifecycle_schema,
      :turn_schema,
      :execution_schema,
      :execution_environment_schema,
      :capability_replay_schema,
      :runtime_limits_schema,
      :evaluation_schema,
      :assertion_schema,
      :usage_schema,
      :error_schema,
      :dimensions_schema,
      :sources_schema
    ]

    Enum.each(functions, fn function ->
      assert apply(Contract, function, []) != nil
    end)

    for function <- [:case_result!, :manifest!, :summary!, :lifecycle!] do
      assert_raise ArgumentError, fn -> apply(Contract, function, [%{}]) end
    end
  end

  test "rejects required fields, invalid statuses, and negative bounds" do
    for invalid <- [
          Map.delete(valid_result(), :run_id),
          put_in(valid_result(), [:execution, :status], :unknown),
          put_in(valid_result(), [:execution, :duration_ms], -1),
          %{valid_result() | sequence: 0}
        ] do
      assert {:error, {:invalid_automation_contract, :case_result, _errors}} =
               Contract.validate_case_result(invalid)
    end
  end

  test "aggregates only numeric usage fields" do
    turns = [
      %{usage: %{input_tokens: 2, total_tokens: 3, provider: "a"}},
      %{usage: %{input_tokens: 4, total_tokens: 7}},
      %{}
    ]

    assert Result.usage(turns) == %{input_tokens: 6, total_tokens: 10}
  end

  test "computes passed, failed, and unscored evaluations" do
    assert Result.evaluation([turn([])], :ok).status == :unscored

    passed = [%{name: :contains, status: :passed}]
    assert Result.evaluation([turn(passed)], :ok).status == :passed

    failed = passed ++ [%{name: :equals, status: :failed}]
    evaluation = Result.evaluation([turn(failed)], :ok)
    assert evaluation.status == :failed
    assert evaluation.assertion_count == 2
    assert evaluation.failed_assertion_count == 1
  end

  test "derives result facts from turns and execution status" do
    turns = [result_turn(:passed, %{input_tokens: 2, total_tokens: 3})]

    result =
      Result.new(cell(),
        execution: Map.put(execution(:ok), :turn_count, 99),
        turns: turns
      )

    assert result.execution.turn_count == 1
    assert result.usage == %{"input_tokens" => 2, "total_tokens" => 3}

    assert result.evaluation == %{
             status: :passed,
             assertion_count: 1,
             failed_assertion_count: 0
           }

    failed = Result.fail(result, :failed_after_execution)
    assert failed.execution.turn_count == 1
    assert failed.usage == result.usage

    assert failed.evaluation == %{
             status: :not_run,
             assertion_count: 0,
             failed_assertion_count: 0
           }
  end

  test "rejects caller-owned derived values and invalid execution status" do
    for derived <- [
          [evaluation: %{status: :failed}],
          [usage: %{total_tokens: 99}]
        ] do
      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        Result.new(cell(), [execution: execution(:ok)] ++ derived)
      end
    end

    assert_raise ArgumentError, ~r/invalid automation execution status/, fn ->
      Result.new(cell(), execution: execution(:unknown))
    end
  end

  defp turn(assertions), do: %{evaluation: %{assertions: assertions}}

  defp result_turn(status, usage) do
    %{
      turn_id: "turn",
      input: "input",
      status: :ok,
      duration_ms: 1,
      response: nil,
      evaluation: %{status: status, assertions: [%{name: :contains, status: status}]},
      observations: %{},
      usage: usage
    }
  end

  defp valid_result do
    Result.new(cell(),
      execution: execution(:error),
      error: Result.error(:failed)
    )
  end

  defp execution(status) do
    %{
      status: status,
      started_at: "2026-08-12T12:00:00Z",
      duration_ms: 0
    }
  end

  defp cell do
    %{
      run_id: "run",
      cell_id: "cell",
      sequence: 2,
      dimensions: %{
        suite_id: "suite",
        agent_key: "agent",
        agent_spec_id: "agent",
        scenario_id: "scenario",
        model_key: "declared",
        model_ref: "openai:test",
        trial: 1
      },
      sources: %{
        agent_file: "agent.yml",
        scenario_file: "scenario.yml",
        agent_sha256: "agent-sha",
        effective_agent_sha256: "effective-sha",
        scenario_sha256: "scenario-sha"
      }
    }
  end

  defp resolved_environment do
    request = PolicyRequest.new!(profile_id: "restricted", capability_ids: ["tools.shell"])

    profile =
      SecurityProfile.new!(
        profile_id: "restricted",
        revision: 1,
        digest: @profile_digest,
        adapter_id: "test.result-adapter",
        required_isolation: :container,
        required_network: :disabled,
        required_workspace: :ephemeral,
        required_image_digest: @image_digest,
        checkpoint_required: true,
        retention: :ephemeral
      )

    capabilities =
      AdapterCapabilities.new!(
        adapter_id: "test.result-adapter",
        adapter_version: "1",
        isolations: [:container],
        networks: [:disabled],
        workspaces: [:ephemeral],
        immutable_image_evidence: true,
        checkpoint: true
      )

    registration =
      Registration.new!(
        profile: profile,
        adapter: __MODULE__,
        capabilities: capabilities,
        metadata: %{
          "api_key" => "secret-marker",
          "host_path" => "/private/host/path"
        }
      )

    %{request: request, registration: registration}
  end

  defp completed_environment(%{request: request, registration: registration}) do
    evidence =
      EnforcementEvidence.new!(
        status: :confirmed,
        adapter_id: "test.result-adapter",
        backend: "test-backend",
        isolation: :container,
        network: :disabled,
        workspace: :ephemeral,
        image_digest: @image_digest,
        applied_limits: %{
          "memory_mb" => 256,
          "command" => "secret-marker",
          "host_path" => "/private/host/path"
        },
        checkpoint: %{
          "supported" => true,
          "forkable" => false,
          "note" => "secret-marker",
          "provider_ref" => "/private/host/path"
        },
        observed_at_ms: 10
      )

    binding =
      Binding.new!(
        adapter_id: "test.result-adapter",
        adapter_version: "1",
        profile_id: "restricted",
        profile_digest: registration.profile.digest,
        resource_ref: "resource-private",
        revision: 1,
        state: :available
      )

    checkpoint =
      Checkpoint.new!(
        checkpoint_ref: "checkpoint-private",
        binding_revision: 1,
        profile_digest: registration.profile.digest,
        evidence_digest: ExecutionEnvironment.digest(evidence),
        preserves: %{"files" => true},
        forkable: false,
        created_at_ms: 10
      )

    Environment.new!(
      status: :cleaned,
      retention: :ephemeral,
      request: request,
      binding: binding,
      checkpoint: checkpoint,
      evidence: evidence
    )
  end
end
