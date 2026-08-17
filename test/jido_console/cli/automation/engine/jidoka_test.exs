defmodule Jido.Console.Automation.Engine.JidokaTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Automation.Engine
  alias Jido.Console.Automation.Engine.Jidoka, as: JidokaEngine
  alias Jidoka.Agent.Spec
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Cancellation
  alias Jidoka.Effect
  alias Jidoka.ExecutionEnvironment
  alias Jidoka.ExecutionEnvironment.AdapterCapabilities
  alias Jidoka.ExecutionEnvironment.Binding
  alias Jidoka.ExecutionEnvironment.Checkpoint
  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.ProfileResolver
  alias Jidoka.ExecutionEnvironment.Registration
  alias Jidoka.ExecutionEnvironment.SecurityProfile
  alias Jidoka.Policy.Decision
  alias Jidoka.Runtime.LocalOperations

  @profile_digest "sha256:" <> String.duplicate("a", 64)
  @image_digest "sha256:" <> String.duplicate("b", 64)

  defmodule EnvironmentAdapter do
    @behaviour Jidoka.ExecutionEnvironment.Adapter

    alias Jidoka.ExecutionEnvironment
    alias Jidoka.ExecutionEnvironment.Binding
    alias Jidoka.ExecutionEnvironment.Checkpoint
    alias Jidoka.ExecutionEnvironment.EnforcementEvidence

    @impl true
    def open(profile, _request, opts) do
      record(opts, :open)

      if Keyword.get(opts, :fail_open, false) do
        {:error, :open_failed}
      else
        binding =
          Binding.new!(
            adapter_id: profile.adapter_id,
            adapter_version: "1",
            profile_id: profile.profile_id,
            profile_digest: profile.digest,
            resource_ref: Keyword.get(opts, :resource_ref, "automation-cell"),
            state: :available
          )

        {:ok, binding, evidence()}
      end
    end

    @impl true
    def acquire(binding, opts) do
      record(opts, :acquire)
      {:ok, %{resource_ref: binding.resource_ref}, evidence()}
    end

    @impl true
    def checkpoint(_handle, %Binding{} = binding, opts) do
      record(opts, :checkpoint)
      binding = %Binding{binding | revision: binding.revision + 1}

      checkpoint =
        Checkpoint.new!(
          checkpoint_ref: "checkpoint-#{binding.resource_ref}-#{binding.revision}",
          binding_revision: binding.revision,
          profile_digest: binding.profile_digest,
          evidence_digest: ExecutionEnvironment.digest(evidence()),
          preserves: %{"files" => true},
          forkable: false,
          created_at_ms: binding.revision
        )

      {:ok, binding, checkpoint, evidence()}
    end

    @impl true
    def restore(binding, _checkpoint, opts) do
      record(opts, :restore)
      {:ok, binding, evidence()}
    end

    @impl true
    def fork(_binding, _checkpoint, _opts), do: {:error, :unsupported}

    @impl true
    def close(_handle, opts) do
      record(opts, :close)
      {:ok, evidence()}
    end

    @impl true
    def cleanup(_binding, opts) do
      record(opts, :cleanup)

      if Keyword.get(opts, :fail_cleanup, false),
        do: {:error, :cleanup_failed},
        else: {:ok, evidence()}
    end

    defp evidence do
      EnforcementEvidence.new!(
        status: :confirmed,
        adapter_id: "test.cli-environment",
        backend: "test-backend",
        isolation: :container,
        network: :disabled,
        workspace: :ephemeral,
        image_digest: "sha256:" <> String.duplicate("b", 64),
        applied_limits: %{},
        checkpoint: %{"supported" => true, "forkable" => false},
        observed_at_ms: 10
      )
    end

    defp record(opts, event), do: Agent.update(Keyword.fetch!(opts, :probe), &[event | &1])
  end

  test "runs ordered turns in one session and carries prior agent state" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    llm = fn intent, _journal, _context ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})

      messages = intent.payload |> get_key(:prompt) |> get_key(:messages, [])

      case call do
        0 ->
          {:ok, %{type: :final, content: "Stored Atlas"}}

        1 ->
          assert Enum.any?(messages, fn message ->
                   Map.get(message, :role) == :assistant and
                     Map.get(message, :content) == "Stored Atlas"
                 end)

          {:ok, %{type: :final, content: "Atlas"}}
      end
    end

    spec =
      Spec.new!(
        id: "memory_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Remember facts from earlier turns."
      )

    cell = %{
      run_id: "run-fixed",
      cell_id: String.duplicate("a", 64),
      sequence: 1,
      dimensions: %{
        suite_id: "multi",
        agent_key: "memory",
        agent_spec_id: "memory_agent",
        scenario_id: "remember",
        model_key: "declared",
        model_ref: "openai:gpt-4o-mini",
        trial: 1
      },
      sources: sources(),
      spec: spec,
      runtime_opts: [llm: llm],
      scenario: %{
        turns: [
          %{
            id: "store",
            input: "My project is Atlas.",
            context: %{},
            assertions: %{contains: "Atlas"}
          },
          %{
            id: "recall",
            input: "What is my project?",
            context: %{},
            assertions: %{equals: "Atlas"}
          }
        ]
      }
    }

    result = Engine.run(JidokaEngine, cell, [])

    assert result.execution.status == :ok, inspect(result.error)
    assert result.evaluation.status == :passed
    assert Enum.map(result.turns, & &1.response.content) == ["Stored Atlas", "Atlas"]
    assert Enum.map(result.turns, & &1.evaluation.status) == [:passed, :passed]
    assert Agent.get(calls, & &1) == 2
  end

  test "starts a fresh session for each matrix cell" do
    llm = fn intent, _journal, _context ->
      messages = intent.payload |> get_key(:prompt) |> get_key(:messages, [])

      refute Enum.any?(messages, fn message ->
               get_key(message, :role) == :assistant and
                 get_key(message, :content) == "private answer"
             end)

      {:ok, %{type: :final, content: "private answer"}}
    end

    spec =
      Spec.new!(
        id: "isolated_cell_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Keep cell state isolated."
      )

    first =
      cell(spec, %{id: "one", input: "First", context: %{}, assertions: %{}})
      |> Map.put(:runtime_opts, llm: llm)

    second =
      cell(spec, %{id: "one", input: "Second", context: %{}, assertions: %{}})
      |> Map.put(:cell_id, String.duplicate("d", 64))
      |> Map.put(:runtime_opts, llm: llm)

    assert Engine.run(JidokaEngine, first, []).execution.status == :ok
    assert Engine.run(JidokaEngine, second, []).execution.status == :ok
  end

  test "reports an assertion failure without changing execution status" do
    llm = fn _intent, _journal, _context ->
      {:ok, %{type: :final, content: "actual"}}
    end

    spec =
      Spec.new!(
        id: "assertion_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    cell = %{
      run_id: "run-fixed",
      cell_id: String.duplicate("b", 64),
      sequence: 1,
      dimensions: %{
        suite_id: "assertions",
        agent_key: "agent",
        agent_spec_id: "assertion_agent",
        scenario_id: "failure",
        model_key: "declared",
        model_ref: "openai:gpt-4o-mini",
        trial: 1
      },
      sources: sources(),
      spec: spec,
      runtime_opts: [llm: llm],
      scenario: %{
        turns: [
          %{id: "one", input: "Answer", context: %{}, assertions: %{equals: "expected"}}
        ]
      }
    }

    result = Engine.run(JidokaEngine, cell, [])
    assert result.execution.status == :ok, inspect(result.error)
    assert result.evaluation.status == :failed
    assert result.evaluation.failed_assertion_count == 1
  end

  test "uses only each sequence step operation results for assertions" do
    llm = fn intent, journal, _context ->
      messages = intent.payload |> get_key(:prompt) |> get_key(:messages, [])
      current_user_message = current_user_message(messages)

      cond do
        current_user_message =~ "Call lookup" and count_results(journal, :llm) == 0 ->
          {:ok, %{type: :operation, name: "lookup", arguments: %{}}}

        current_user_message =~ "Call lookup" ->
          {:ok, %{type: :final, content: "lookup done"}}

        true ->
          {:ok, %{type: :final, content: "second answer"}}
      end
    end

    operations =
      LocalOperations.operations(%{
        "lookup" => fn _arguments, _context -> %{value: "found"} end
      })

    spec =
      Spec.new!(
        id: "operation_scope_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Use tools when asked.",
        operations: [
          Operation.new!(name: "lookup", description: "Looks up data.", idempotency: :idempotent)
        ]
      )

    result =
      Engine.run(
        JidokaEngine,
        cell(spec, [
          %{
            id: "first",
            input: "Call lookup.",
            context: %{},
            assertions: %{operation_called: "lookup"}
          },
          %{
            id: "second",
            input: "Answer without a tool.",
            context: %{},
            assertions: %{operation_called: "lookup"}
          }
        ])
        |> Map.put(:runtime_opts, llm: llm, operations: operations),
        []
      )

    assert result.execution.status == :ok
    assert result.evaluation.status == :failed
    assert Enum.at(result.turns, 0).observations.operation_calls == ["lookup"]
    assert Enum.at(result.turns, 0).evaluation.status == :passed
    assert Enum.at(result.turns, 1).observations.operation_calls == []
    assert Enum.at(result.turns, 1).evaluation.status == :failed
  end

  test "reports a runtime failure and keeps the interrupted turn" do
    llm = fn _intent, _journal, _context -> {:error, :provider_offline} end

    spec =
      Spec.new!(
        id: "error_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    cell =
      spec
      |> cell(%{id: "failure", input: "Answer", context: %{}, assertions: %{}})
      |> Map.put(:runtime_opts, llm: llm)

    result = Engine.run(JidokaEngine, cell, [])

    assert result.execution.status == :error
    assert result.evaluation.status == :not_run
    assert [%{turn_id: "failure", status: :error, error: error}] = result.turns
    assert is_binary(error.message)
  end

  test "keeps the completed prefix and stops after a sequence error" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    llm = fn _intent, _journal, _context ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:ok, %{type: :final, content: "first complete"}}
        1 -> {:error, :provider_offline}
        _call -> flunk("a later scenario turn ran after the sequence error")
      end
    end

    spec =
      Spec.new!(
        id: "prefix_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    result =
      Engine.run(
        JidokaEngine,
        cell(spec, [
          %{id: "one", input: "First", context: %{}, assertions: %{}},
          %{id: "two", input: "Fail", context: %{}, assertions: %{}},
          %{id: "three", input: "Never", context: %{}, assertions: %{}}
        ])
        |> Map.put(:runtime_opts, llm: llm),
        []
      )

    assert result.execution.status == :error
    assert Enum.map(result.turns, & &1.status) == [:ok, :error]
    assert Enum.map(result.turns, & &1.turn_id) == ["one", "two"]
    assert Agent.get(calls, & &1) == 2
  end

  test "maps a later sequence hibernation and stops the remaining turns" do
    llm = fn intent, journal, _context ->
      messages = intent.payload |> get_key(:prompt) |> get_key(:messages, [])
      current_user_message = current_user_message(messages)

      cond do
        current_user_message =~ "First" ->
          {:ok, %{type: :final, content: "first complete"}}

        count_results(journal, :llm) == 0 ->
          {:ok, %{type: :operation, name: "unsafe_change", arguments: %{}}}

        true ->
          {:ok, %{type: :final, content: "never"}}
      end
    end

    operations =
      LocalOperations.operations(%{
        "unsafe_change" => fn _arguments, _context -> flunk("reviewed operation ran") end
      })

    spec =
      Spec.new!(
        id: "hibernate_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Use the requested tool.",
        operations: [
          Operation.new!(
            name: "unsafe_change",
            description: "Changes data.",
            idempotency: :unsafe_once,
            approval: true
          )
        ]
      )

    result =
      Engine.run(
        JidokaEngine,
        cell(spec, [
          %{id: "one", input: "First", context: %{}, assertions: %{}},
          %{id: "two", input: "Change data", context: %{}, assertions: %{}},
          %{id: "three", input: "Never", context: %{}, assertions: %{}}
        ])
        |> Map.put(:runtime_opts, llm: llm, operations: operations),
        []
      )

    assert result.execution.status == :hibernated
    assert Enum.map(result.turns, & &1.status) == [:ok, :hibernated]
    assert Enum.map(result.turns, & &1.turn_id) == ["one", "two"]
  end

  test "cancels through the public sequence handle and keeps completed turns" do
    parent = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    llm = fn _intent, _journal, context ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 ->
          {:ok, %{type: :final, content: "first complete"}}

        1 ->
          send(parent, {:engine_sequence_started, self()})
          :ok = wait_for_cancellation(context, 1_000)
          {:error, :cancelled}

        _call ->
          flunk("a later engine turn started after cancellation")
      end
    end

    spec =
      Spec.new!(
        id: "cancel_engine_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    cell =
      cell(spec, [
        %{id: "one", input: "First", context: %{}, assertions: %{}},
        %{id: "two", input: "Block", context: %{}, assertions: %{}},
        %{id: "three", input: "Never", context: %{}, assertions: %{}}
      ])
      |> Map.put(:runtime_opts, llm: llm)

    assert {:ok, request} = JidokaEngine.start(cell, [])
    refute Map.has_key?(request, :sequence)
    assert_receive {:engine_sequence_started, capability_pid}, 5_000

    assert {:ok, %Cancellation{} = cancellation} = JidokaEngine.cancel(request, grace_ms: 500)
    result = JidokaEngine.await(request, automation_await_timeout: 100)

    assert result.execution.status == :cancelled
    assert Enum.map(result.turns, & &1.status) == [:ok, :cancelled]
    assert Enum.map(result.turns, & &1.turn_id) == ["one", "two"]
    assert result.turns |> hd() |> get_in([:response, :content]) == "first complete"
    assert result.error.details["cause"]["request_id"] == cancellation.request_id
    refute Process.alive?(capability_pid)
    assert Agent.get(calls, & &1) == 2
  end

  test "passes one resolved environment to the public sequence for the full cell" do
    {:ok, probe} = Agent.start_link(fn -> [] end)
    parent = self()

    llm = fn _intent, _journal, context ->
      send(parent, {:cell_environment, Jidoka.Context.runtime(context)})
      {:ok, %{type: :final, content: "done"}}
    end

    spec =
      Spec.new!(
        id: "profiled_cell_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer in the constrained environment."
      )

    profiled_cell =
      cell(spec, [
        %{id: "one", input: "First", context: %{}, assertions: %{}},
        %{id: "two", input: "Second", context: %{}, assertions: %{}}
      ])
      |> Map.put(:runtime_opts, llm: llm)
      |> Map.put(:execution_environment, resolved_environment())

    result =
      Engine.run(JidokaEngine, profiled_cell,
        execution_environment_policy: allow_environment_policy(),
        execution_environment_adapter_opts: [probe: probe]
      )

    assert result.execution.status == :ok, inspect(result.error)
    assert Enum.map(result.turns, & &1.status) == [:ok, :ok]
    assert result.execution_environment.status == :closed
    assert result.execution_environment.requested.profile_id == "restricted"
    assert result.execution_environment.confirmed.backend == "test-backend"
    assert result.execution_environment.lifecycle.cleanup == :confirmed

    assert_receive {:cell_environment,
                    %{execution_environment: %{handle: %Jidoka.ExecutionEnvironment.Manager.Handle{}}}}

    assert_receive {:cell_environment,
                    %{execution_environment: %{handle: %Jidoka.ExecutionEnvironment.Manager.Handle{}}}}

    assert environment_events(probe) == [
             :open,
             :acquire,
             :checkpoint,
             :close,
             :acquire,
             :checkpoint,
             :close,
             :cleanup
           ]
  end

  test "fails a profiled cell before execution when trusted policy is absent" do
    {:ok, probe} = Agent.start_link(fn -> [] end)
    parent = self()

    spec =
      Spec.new!(
        id: "missing_policy_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    profiled_cell =
      spec
      |> cell(%{id: "one", input: "Blocked", context: %{}, assertions: %{}})
      |> Map.put(
        :runtime_opts,
        llm: fn _intent, _journal, _context ->
          send(parent, :profiled_llm_called)
          {:ok, %{type: :final, content: "unsafe"}}
        end
      )
      |> Map.put(:execution_environment, resolved_environment())

    result =
      Engine.run(JidokaEngine, profiled_cell, execution_environment_adapter_opts: [probe: probe])

    assert result.execution.status == :error
    assert result.execution_environment.status == :rejected
    refute Map.has_key?(result.execution_environment, :confirmed)
    refute_received :profiled_llm_called
    assert environment_events(probe) == []
  end

  test "closes and cleans the cell environment after a model error" do
    {:ok, probe} = Agent.start_link(fn -> [] end)

    spec =
      Spec.new!(
        id: "profiled_error_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    profiled_cell =
      spec
      |> cell(%{id: "one", input: "Fail", context: %{}, assertions: %{}})
      |> Map.put(:runtime_opts, llm: fn _intent, _journal, _context -> {:error, :offline} end)
      |> Map.put(:execution_environment, resolved_environment())

    result =
      Engine.run(JidokaEngine, profiled_cell,
        execution_environment_policy: allow_environment_policy(),
        execution_environment_adapter_opts: [probe: probe]
      )

    assert result.execution.status == :error
    assert result.execution_environment.status == :closed
    assert result.execution_environment.confirmed.status == :confirmed
    assert environment_events(probe) == [:open, :acquire, :close, :cleanup]
  end

  test "keeps confirmed evidence when cleanup fails" do
    {:ok, probe} = Agent.start_link(fn -> [] end)

    spec =
      Spec.new!(
        id: "profiled_cleanup_error_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    profiled_cell =
      spec
      |> cell(%{id: "one", input: "Answer", context: %{}, assertions: %{}})
      |> Map.put(
        :runtime_opts,
        llm: fn _intent, _journal, _context -> {:ok, %{type: :final, content: "done"}} end
      )
      |> Map.put(:execution_environment, resolved_environment())

    result =
      Engine.run(JidokaEngine, profiled_cell,
        execution_environment_policy: allow_environment_policy(),
        execution_environment_adapter_opts: [probe: probe, fail_cleanup: true]
      )

    assert result.execution.status == :error
    assert result.execution_environment.status == :cleanup_failed
    assert result.execution_environment.confirmed.status == :confirmed
    assert result.execution_environment.lifecycle.close == :confirmed
    assert result.execution_environment.lifecycle.cleanup == :failed
    assert environment_events(probe) == [:open, :acquire, :checkpoint, :close, :cleanup]
  end

  test "keeps requested facts when environment open fails" do
    {:ok, probe} = Agent.start_link(fn -> [] end)

    spec =
      Spec.new!(
        id: "profiled_open_error_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    profiled_cell =
      spec
      |> cell(%{id: "one", input: "Answer", context: %{}, assertions: %{}})
      |> Map.put(:execution_environment, resolved_environment())

    result =
      Engine.run(JidokaEngine, profiled_cell,
        execution_environment_policy: allow_environment_policy(),
        execution_environment_adapter_opts: [probe: probe, fail_open: true]
      )

    assert result.execution.status == :error
    assert result.execution_environment.status == :open_failed
    assert result.execution_environment.requested.profile_id == "restricted"
    refute Map.has_key?(result.execution_environment, :confirmed)
    assert environment_events(probe) == [:open]
  end

  test "supports unscored turns and injected clocks" do
    llm = fn _intent, _journal, _context -> {:ok, %{type: :final, content: "answer"}} end

    spec =
      Spec.new!(
        id: "clock_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    {:ok, clock} = Agent.start_link(fn -> 10 end)

    monotonic_ms = fn -> Agent.get_and_update(clock, &{&1, &1 + 5}) end
    utc_now = fn -> ~U[2026-08-12 12:00:00Z] end

    cell =
      spec
      |> cell(%{id: "plain", input: "Answer", context: %{}, assertions: %{}})
      |> Map.put(:runtime_opts, llm: llm)

    result = Engine.run(JidokaEngine, cell, monotonic_ms: monotonic_ms, utc_now: utc_now)

    assert result.execution.status == :ok
    assert result.execution.started_at == "2026-08-12T12:00:00Z"
    assert result.evaluation.status == :unscored
    assert result.execution.duration_ms > 0
  end

  test "reports invalid request data before a session turn" do
    spec =
      Spec.new!(
        id: "invalid_request_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    result =
      Engine.run(
        JidokaEngine,
        cell(spec, %{id: "bad", input: "Answer", context: [:not, :a, :map], assertions: %{}}),
        []
      )

    assert result.execution.status == :error
    assert [%{status: :error}] = result.turns
  end

  defp cell(spec, turn) do
    %{
      run_id: "run-fixed",
      cell_id: String.duplicate("c", 64),
      sequence: 1,
      dimensions: %{
        suite_id: "engine",
        agent_key: "agent",
        agent_spec_id: spec.id,
        scenario_id: "engine",
        model_key: "declared",
        model_ref: "openai:gpt-4o-mini",
        trial: 1
      },
      sources: sources(),
      spec: spec,
      runtime_opts: [],
      scenario: %{turns: List.wrap(turn)}
    }
  end

  defp count_results(%Effect.Journal{results: results}, kind) do
    results |> Map.values() |> Enum.count(&(&1.kind == kind))
  end

  defp get_key(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp current_user_message(messages) do
    case messages |> Enum.filter(&(get_key(&1, :role) in [:user, "user"])) |> List.last() do
      nil -> ""
      message -> get_key(message, :content, "")
    end
  end

  defp wait_for_cancellation(_context, 0), do: {:error, :cancellation_not_received}

  defp wait_for_cancellation(context, attempts_left) do
    if Cancellation.requested?(context) do
      :ok
    else
      Process.sleep(1)
      wait_for_cancellation(context, attempts_left - 1)
    end
  end

  defp resolved_environment do
    request = PolicyRequest.new!(profile_id: "restricted")

    profile =
      SecurityProfile.new!(
        profile_id: "restricted",
        revision: 1,
        digest: @profile_digest,
        adapter_id: "test.cli-environment",
        required_isolation: :container,
        required_network: :disabled,
        required_workspace: :ephemeral,
        required_image_digest: @image_digest,
        checkpoint_required: true,
        retention: :ephemeral
      )

    capabilities =
      AdapterCapabilities.new!(
        adapter_id: "test.cli-environment",
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
        adapter: EnvironmentAdapter,
        capabilities: capabilities
      )

    {:ok, selection} =
      ProfileResolver.resolve(request, fn _profile_id, _opts -> {:ok, registration} end)

    %{selection: selection}
  end

  defp allow_environment_policy do
    fn _request, _context -> {:ok, Decision.new!(outcome: :allow, rule_id: "test.allow")} end
  end

  defp environment_events(probe), do: Agent.get(probe, &Enum.reverse/1)

  defp sources do
    %{
      agent_file: "agent.yml",
      scenario_file: "scenario.yml",
      agent_sha256: "agent-sha",
      effective_agent_sha256: "effective-agent-sha",
      scenario_sha256: "scenario-sha"
    }
  end
end
