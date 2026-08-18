defmodule Jido.Console.Session.AdmissionTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{Admission, Event, Generation, Identity, Reducer, State}
  alias Jido.Console.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "jido-admission-#{System.unique_integer([:positive])}")

    names = [
      name: unique(:supervisor),
      lock: unique(:lock),
      maintenance: unique(:maintenance),
      quota: unique(:quota),
      admission: unique(:admission),
      writer: unique(:writer),
      jido_home: root
    ]

    assert {:ok, supervisor} = Jido.Console.Storage.Supervisor.start_link(names)
    on_exit(fn -> File.rm_rf(root) end)

    storage = Keyword.take(names, [:writer, :quota, :admission])
    %{root: root, names: names, storage: storage, supervisor: supervisor}
  end

  test "commits one exact input receipt and event and returns it after restart", context do
    session_id = "session-admission"
    {:ok, fence} = claim(session_id, context.storage)
    identity = session_identity(session_id, fence)

    assert {:ok, prepared} =
             Admission.prepare(:send, %{"text" => "hello", "operation" => "send"},
               session_id: session_id,
               principal_id: "client-one",
               idempotency_key: "input-one",
               generation: fence.generation,
               sequence: 1
             )

    event = input_event(identity, prepared.target_id, 1)
    assert {:ok, semantic} = Reducer.apply_event(State.new(session_id), event)

    assert {:ok, first} = Admission.commit(prepared, event, semantic, fence, context.storage)
    assert first.duplicate == false
    assert first.receipt["family"] == "receipt"
    assert first.receipt["type"] == "input"
    assert first.receipt["payload"]["status"] == "committed"
    assert first.receipt["payload"]["sequence"] == 1

    assert {:ok, duplicate} = Admission.commit(prepared, event, semantic, fence, context.storage)
    assert duplicate.duplicate == true
    assert duplicate.receipt == first.receipt

    assert {:ok, head} = Storage.history_head(session_id, context.storage)
    assert head.sequence == 1

    Supervisor.stop(context.supervisor)
    assert {:ok, _restarted} = Jido.Console.Storage.Supervisor.start_link(context.names)

    assert {:ok, looked_up} = Admission.receipt(prepared.operation_id, context.storage)
    assert looked_up == first.receipt
    assert {:ok, [recovered]} = Admission.recover(session_id, context.storage)
    assert recovered == first.receipt
  end

  test "returns a conflict for changed data and leaves the first commit unchanged", context do
    session_id = "session-conflict"
    {:ok, fence} = claim(session_id, context.storage)
    identity = session_identity(session_id, fence)

    first = prepare!(session_id, fence, "same-key", "first")
    first_event = input_event(identity, first.target_id, 1)
    {:ok, first_state} = Reducer.apply_event(State.new(session_id), first_event)
    assert {:ok, committed} = Admission.commit(first, first_event, first_state, fence, context.storage)

    changed = prepare!(session_id, fence, "same-key", "changed")
    changed_event = input_event(identity, changed.target_id, 1)
    {:ok, changed_state} = Reducer.apply_event(State.new(session_id), changed_event)

    assert {:error, {:idempotency_conflict, receipt_id}} =
             Admission.commit(changed, changed_event, changed_state, fence, context.storage)

    assert receipt_id == committed.receipt["id"]
    assert {:ok, looked_up} = Admission.receipt(first.operation_id, context.storage)
    assert looked_up == committed.receipt
    assert {:ok, %{sequence: 1}} = Storage.history_head(session_id, context.storage)
  end

  test "persists idempotent admission lifecycle transitions and filters recovery", context do
    session_id = "session-lifecycle"
    {:ok, fence} = claim(session_id, context.storage)
    identity = session_identity(session_id, fence)
    prepared = prepare!(session_id, fence, "lifecycle-key", "start me")
    event = input_event(identity, prepared.target_id, 1)
    {:ok, semantic} = Reducer.apply_event(State.new(session_id), event)

    assert {:ok, accepted} = Admission.commit(prepared, event, semantic, fence, context.storage)
    assert accepted.receipt["payload"]["admission_state"] == "accepted"
    assert {:ok, []} = Admission.recover(session_id, context.storage ++ [states: ["started"]])

    assert {:ok, started} =
             Admission.transition(prepared.operation_id, "started", fence, context.storage)

    assert started.duplicate == false
    assert started.receipt["payload"]["admission_state"] == "started"

    assert {:ok, started_retry} =
             Admission.transition(prepared.operation_id, "started", fence, context.storage)

    assert started_retry.duplicate == true
    assert started_retry.receipt == started.receipt
    assert {:ok, []} = Admission.recover(session_id, context.storage ++ [states: ["accepted"]])
    assert {:ok, [recovered_started]} = Admission.recover(session_id, context.storage ++ [states: ["started"]])
    assert recovered_started == started.receipt

    assert {:ok, terminal} =
             Admission.transition(prepared.operation_id, "terminal", fence, context.storage)

    assert terminal.duplicate == false
    assert terminal.receipt["payload"]["admission_state"] == "terminal"

    reverse_operation_id = prepared.operation_id <> ":reverse"

    assert {:error, {:invalid_admission_transition, "terminal", "started"}} =
             Storage.transition_admission(
               prepared.operation_id,
               "started",
               context.storage ++
                 [
                   operation_id: reverse_operation_id,
                   fence: Generation.for_operation(fence, reverse_operation_id)
                 ]
             )

    assert {:ok, %{integrity: :ok}} = Storage.inspect_store(context.storage)

    Supervisor.stop(context.supervisor)
    assert {:ok, _restarted} = Jido.Console.Storage.Supervisor.start_link(context.names)
    assert {:ok, []} = Admission.recover(session_id, context.storage ++ [states: ["started"]])

    assert {:ok, [recovered_terminal]} =
             Admission.recover(session_id, context.storage ++ [states: ["terminal"]])

    assert recovered_terminal == terminal.receipt
  end

  test "creates command receipts with normalized effective arguments", context do
    session_id = "session-command"
    {:ok, fence} = claim(session_id, context.storage)
    identity = session_identity(session_id, fence)

    assert {:ok, prepared} =
             Admission.prepare(:invoke, %{command_id: "cmd_help", data: %{page: 1}},
               session_id: session_id,
               principal_id: "client-command",
               idempotency_key: "command-one",
               generation: fence.generation,
               sequence: 1
             )

    event = command_event(identity, 1)
    {:ok, semantic} = Reducer.apply_event(State.new(session_id), event)
    assert {:ok, result} = Admission.commit(prepared, event, semantic, fence, context.storage)
    assert result.receipt["type"] == "command"
    assert result.receipt["payload"]["result_id"] == prepared.target_id

    assert result.receipt["payload"]["effective_arguments"] == %{
             "command_id" => "cmd_help",
             "data" => %{"page" => 1}
           }
  end

  test "rejects missing keys and credential-bearing structures before persistence", context do
    opts = [
      session_id: "session-rejected",
      principal_id: "client-rejected",
      generation: 1,
      sequence: 1
    ]

    assert {:error, :idempotency_key_required} = Admission.prepare(:send, %{"text" => "hello"}, opts)

    assert {:error, {:sensitive_value_rejected, rejection}} =
             Admission.prepare(
               :start_turn,
               %{"prompt" => "hello", "metadata" => %{"authorization" => "redacted"}},
               Keyword.put(opts, :idempotency_key, "rejected-one")
             )

    assert rejection["redacted"] == true

    assert {:error, {:history_not_found, "session-rejected"}} =
             Storage.history_head("session-rejected", context.storage)

    assert {:error, {:admission_receipt_not_found, _operation_id}} =
             Admission.receipt(
               "admission_" <> String.duplicate("0", 64),
               context.storage
             )
  end

  test "bounds idempotency keys and recovery reads", context do
    assert Admission.limits().idempotency_key_bytes == 128

    assert {:error, {:idempotency_key_too_large, 129, 128}} =
             Admission.prepare(:send, %{"text" => "hello"},
               session_id: "session-bounds",
               principal_id: "client-bounds",
               idempotency_key: String.duplicate("x", 129),
               generation: 1,
               sequence: 1
             )

    assert {:error, :invalid_admission_recovery_bounds} =
             Storage.recover_admissions("session-bounds", context.storage ++ [limit: 1_001])
  end

  test "resolves a commit-unknown timeout by the same operation identity", context do
    session_id = "session-timeout-unknown"
    {:ok, fence} = claim(session_id, context.storage)
    identity = session_identity(session_id, fence)
    prepared = prepare!(session_id, fence, "timeout-key", "slow commit")
    event = input_event(identity, prepared.target_id, 1)
    {:ok, semantic} = Reducer.apply_event(State.new(session_id), event)
    writer = context.storage[:writer]

    :ok = :sys.suspend(writer)

    task =
      Task.async(fn ->
        Admission.commit(prepared, event, semantic, fence, context.storage ++ [deadline: 10])
      end)

    assert {:error, {:timeout_unknown, operation_id}} = Task.await(task, 1_000)
    assert operation_id == prepared.operation_id
    :ok = :sys.resume(writer)

    assert {:ok, receipt} = eventually(fn -> Admission.receipt(operation_id, context.storage) end)
    assert receipt["payload"]["operation_id"] == operation_id
    assert receipt["payload"]["admission_state"] == "accepted"
  end

  test "keeps the crash windows before commit, before wake, and after wake exact", context do
    before = admission_case("crash-before", "before", context.storage)
    parent = self()

    before_worker =
      spawn(fn ->
        send(parent, {:crash_point, :before_commit, self()})

        receive do
          :commit ->
            result =
              Admission.commit(
                before.prepared,
                before.event,
                before.semantic,
                before.fence,
                context.storage
              )

            send(parent, {:commit_result, result})
        end
      end)

    assert_receive {:crash_point, :before_commit, ^before_worker}
    Process.exit(before_worker, :kill)
    refute_receive :advisory_wake, 20

    assert {:error, {:admission_receipt_not_found, _operation_id}} =
             Admission.receipt(before.prepared.operation_id, context.storage)

    assert {:ok, retry} =
             Admission.commit(
               before.prepared,
               before.event,
               before.semantic,
               before.fence,
               context.storage
             )

    assert retry.duplicate == false

    before_wake = admission_case("crash-before-wake", "before-wake", context.storage)

    before_wake_worker =
      spawn(fn ->
        result =
          Admission.commit(
            before_wake.prepared,
            before_wake.event,
            before_wake.semantic,
            before_wake.fence,
            context.storage
          )

        send(parent, {:crash_point, :after_commit, self(), result})

        receive do
          :wake -> send(parent, :advisory_wake)
        end
      end)

    assert_receive {:crash_point, :after_commit, ^before_wake_worker, {:ok, committed}}
    Process.exit(before_wake_worker, :kill)
    refute_receive :advisory_wake, 20

    Supervisor.stop(context.supervisor)
    assert {:ok, restarted} = Jido.Console.Storage.Supervisor.start_link(context.names)

    assert {:ok, [recovered]} = Admission.recover(before_wake.session_id, context.storage)
    assert recovered == committed.receipt

    after_wake = admission_case("crash-after-wake", "after-wake", context.storage)

    after_wake_worker =
      spawn(fn ->
        {:ok, admitted} =
          Admission.commit(
            after_wake.prepared,
            after_wake.event,
            after_wake.semantic,
            after_wake.fence,
            context.storage
          )

        send(parent, :advisory_wake)
        send(parent, {:crash_point, :after_wake, self(), admitted})
        Process.sleep(:infinity)
      end)

    assert_receive :advisory_wake
    assert_receive {:crash_point, :after_wake, ^after_wake_worker, admitted}
    Process.exit(after_wake_worker, :kill)
    Supervisor.stop(restarted)
    assert {:ok, _restarted_again} = Jido.Console.Storage.Supervisor.start_link(context.names)

    assert {:ok, duplicate} =
             Admission.commit(
               after_wake.prepared,
               after_wake.event,
               after_wake.semantic,
               after_wake.fence,
               context.storage
             )

    assert duplicate.duplicate == true
    assert duplicate.receipt == admitted.receipt
    refute_receive :advisory_wake, 20
  end

  defp prepare!(session_id, fence, key, text) do
    {:ok, prepared} =
      Admission.prepare(:send, %{"text" => text, "operation" => "send"},
        session_id: session_id,
        principal_id: "client-one",
        idempotency_key: key,
        generation: fence.generation,
        sequence: 1
      )

    prepared
  end

  defp admission_case(session_id, key, storage) do
    {:ok, fence} = claim(session_id, storage)
    identity = session_identity(session_id, fence)
    prepared = prepare!(session_id, fence, key, key)
    event = input_event(identity, prepared.target_id, 1)
    {:ok, semantic} = Reducer.apply_event(State.new(session_id), event)

    %{
      session_id: session_id,
      fence: fence,
      prepared: prepared,
      event: event,
      semantic: semantic
    }
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      {:ok, _value} = result ->
        result

      _other ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  defp eventually(fun, 0), do: fun.()

  defp claim(session_id, storage) do
    Generation.claim(
      session_id,
      storage ++
        [
          expected_generation: 0,
          owner_instance_id: "owner-one",
          operation_id: "claim-#{session_id}"
        ]
    )
  end

  defp session_identity(session_id, fence) do
    Identity.new!(:session,
      id: session_id,
      generation: fence.generation,
      owner_instance_id: fence.owner_instance_id
    )
  end

  defp input_event(identity, input_id, sequence) do
    event(identity, "input_admitted", sequence, %{
      input_id: input_id,
      client_id: "client-one"
    })
  end

  defp command_event(identity, sequence) do
    event(identity, "command_effected", sequence, %{
      command_id: "cmd_help",
      effect: %{
        "family" => "outcome",
        "type" => "accepted",
        "command_id" => "cmd_help",
        "session_id" => identity.id,
        "data" => %{"page" => 1}
      }
    })
  end

  defp event(identity, type, sequence, extra) do
    {:ok, value} =
      %{
        type: type,
        id: "event-#{identity.id}-#{sequence}",
        session_id: identity.id,
        sequence: sequence,
        durability: "process",
        sensitivity: "public",
        origin: %{kind: "client", actor_id: "client-one"},
        trust: %{evidence: "test", policy: "session-owner"},
        identities: [Identity.to_protocol(identity)]
      }
      |> Map.merge(extra)
      |> Event.classify()

    value
  end

  defp unique(label), do: String.to_atom("jido-admission-#{label}-#{System.unique_integer([:positive])}")
end
