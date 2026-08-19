defmodule Jido.Console.Session.AdmissionTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{Admission, Event, Generation, Reducer, State}
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor

  setup do
    root = Path.join(System.tmp_dir!(), "jido-admission-#{System.unique_integer([:positive])}")
    opts = [name: unique(:supervisor), lock: unique(:lock), writer: unique(:writer), jido_home: root]
    assert {:ok, supervisor} = StorageSupervisor.start_link(opts)
    on_exit(fn -> File.rm_rf(root) end)
    %{opts: opts, supervisor: supervisor}
  end

  test "commits the operation and event atomically and restores its receipt", context do
    session_id = "admission-one"
    {:ok, owner} = Generation.claim(session_id)
    {:ok, prepared} = prepare(session_id, "key-one", %{text: "hello"})
    event = event(session_id, prepared.operation_id)
    {:ok, semantic} = Reducer.apply_event(State.new(session_id), event)

    assert {:ok, %{duplicate: false, receipt: receipt}} =
             Admission.commit(prepared, event, semantic, owner, storage_opts(context.opts))

    assert receipt["payload"]["admission_state"] == "accepted"
    assert {:ok, ^receipt} = Admission.receipt(prepared.operation_id, storage_opts(context.opts))

    Supervisor.stop(context.supervisor)
    assert {:ok, _supervisor} = StorageSupervisor.start_link(context.opts)
    assert {:ok, ^receipt} = Admission.receipt(prepared.operation_id, storage_opts(context.opts))
  end

  test "returns duplicates and rejects changed data for one idempotency key", context do
    session_id = "admission-idempotent"
    {:ok, owner} = Generation.claim(session_id)
    {:ok, prepared} = prepare(session_id, "same-key", %{text: "first"})
    event = event(session_id, prepared.operation_id)
    {:ok, semantic} = Reducer.apply_event(State.new(session_id), event)

    assert {:ok, %{duplicate: false}} =
             Admission.commit(prepared, event, semantic, owner, storage_opts(context.opts))

    assert {:ok, %{duplicate: true}} =
             Admission.commit(prepared, event, semantic, owner, storage_opts(context.opts))

    {:ok, changed} = prepare(session_id, "same-key", %{text: "changed"})

    assert {:error, {:idempotency_conflict, _receipt_id}} =
             Admission.commit(changed, event, semantic, owner, storage_opts(context.opts))
  end

  test "updates one operation state without a transition journal", context do
    session_id = "admission-state"
    {:ok, owner} = Generation.claim(session_id)
    {:ok, prepared} = prepare(session_id, "state-key", %{text: "hello"})
    event = event(session_id, prepared.operation_id)
    {:ok, semantic} = Reducer.apply_event(State.new(session_id), event)
    assert {:ok, _result} = Admission.commit(prepared, event, semantic, owner, storage_opts(context.opts))

    assert {:ok, %{receipt: started, duplicate: false}} =
             Admission.transition(prepared.operation_id, "started", owner, storage_opts(context.opts))

    assert started["payload"]["admission_state"] == "started"

    assert {:ok, %{duplicate: true}} =
             Admission.transition(prepared.operation_id, "started", owner, storage_opts(context.opts))

    assert {:ok, %{receipt: terminal}} =
             Admission.transition(prepared.operation_id, "terminal", owner, storage_opts(context.opts))

    assert terminal["payload"]["admission_state"] == "terminal"
  end

  test "rejects secret-bearing data before storage", _context do
    assert {:error, {:sensitive_value_rejected, _details}} =
             prepare("admission-secret", "secret-key", %{"token" => "do-not-store"})
  end

  defp prepare(session_id, key, payload) do
    Admission.prepare(:send, payload,
      session_id: session_id,
      principal_id: "client-one",
      idempotency_key: key,
      sequence: 1
    )
  end

  defp event(session_id, operation_id) do
    {:ok, event} =
      Event.classify(%{
        "id" => "event-#{operation_id}",
        "session_id" => session_id,
        "type" => "input_admitted",
        "sequence" => 1,
        "durability" => "process",
        "sensitivity" => "public",
        "origin" => %{"kind" => "client", "actor_id" => "client-one"},
        "trust" => %{"evidence" => "test", "policy" => "test"}
      })

    event
  end

  defp storage_opts(opts), do: [writer: opts[:writer], deadline: 1_000]
  defp unique(label), do: String.to_atom("#{label}-#{System.unique_integer([:positive])}")
end
