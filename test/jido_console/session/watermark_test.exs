defmodule Jido.Console.Session.WatermarkTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.Durable.JidokaValue
  alias Jido.Console.Session.{Event, Generation, Watermark}
  alias Jido.Console.Session.Jidoka, as: SessionJidoka
  alias Jido.Console.Session.Store.SQLite
  alias Jido.Console.Storage
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor
  alias Jidoka.Session.Data, as: JidokaData
  alias Jidoka.Session.Store, as: JidokaStore
  alias Jidoka.Snapshot, as: JidokaSnapshot
  alias Jidoka.Turn, as: JidokaTurn

  setup do
    token = 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    root = Path.join(System.tmp_dir!(), "jido-watermark-#{token}")

    names = [
      name: unique(:supervisor),
      lock: unique(:lock),
      maintenance: unique(:maintenance),
      quota: unique(:quota),
      admission: unique(:admission),
      writer: unique(:writer),
      jido_home: root
    ]

    assert {:ok, supervisor} = StorageSupervisor.start_link(names)
    Process.unlink(supervisor)
    storage = Keyword.take(names, [:writer, :quota, :admission])

    on_exit(fn ->
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
      File.rm_rf(root)
    end)

    %{root: root, storage: storage, writer: names[:writer], names: names, supervisor: supervisor}
  end

  test "commits verified last and resumes idempotently after every crash barrier", context do
    prepared = prepare_boundary(context, "session-crash", "watermark-crash")

    assert {:error, {:injected_watermark_crash, :after_reserved}} =
             Watermark.reserve(prepared.boundary, prepared.fence, context.storage ++ [crash_at: :after_reserved])

    persist_checkpoint(context, prepared)
    persist_projection(context, prepared)

    assert {:error, {:injected_watermark_crash, :after_jidoka_committed}} =
             Watermark.verify(
               prepared.watermark_id,
               prepared.fence,
               context.storage ++ [crash_at: :after_jidoka_committed]
             )

    assert {:error, {:injected_watermark_crash, :after_console_committed}} =
             Watermark.verify(
               prepared.watermark_id,
               prepared.fence,
               context.storage ++ [crash_at: :after_console_committed]
             )

    assert {:error, {:injected_watermark_crash, :after_verified}} =
             Watermark.verify(prepared.watermark_id, prepared.fence, context.storage ++ [crash_at: :after_verified])

    assert {:ok, %{status: :verified, exact_resume: true, duplicate: true}} =
             Watermark.verify(prepared.watermark_id, prepared.fence, context.storage)

    assert {:ok, inspection} = Watermark.inspect(prepared.watermark_id, context.storage)
    assert inspection.state == "verified"
    assert inspection.exact_resume

    assert Enum.map(inspection.transitions, & &1.state) ==
             ~w(reserved jidoka_committed console_committed verified)

    assert {:ok, latest} = Storage.verified_watermark(prepared.session_id, context.storage)
    assert latest.watermark_id == prepared.watermark_id
    assert latest.state == "verified"
  end

  test "repairs a Jidoka-only checkpoint with a deterministic provider-free projection", context do
    prepared = prepare_boundary(context, "session-repair", "watermark-repair")
    assert {:ok, _reserved} = Watermark.reserve(prepared.boundary, prepared.fence, context.storage)
    persist_checkpoint(context, prepared)

    assert {:ok,
            %{
              status: :repair_required,
              missing_side: :console,
              action: :repair_console_projection,
              exact_resume: false
            }} = Watermark.verify(prepared.watermark_id, prepared.fence, context.storage)

    assert {:ok, %{status: :verified, exact_resume: true}} =
             Watermark.repair_projection(prepared.watermark_id, prepared.fence, context.storage)

    assert {:ok, event} =
             Storage.canonical_event(prepared.boundary["console_identity"]["event_id"], context.storage)

    assert event.chain_digest == prepared.boundary["console_digest"]
  end

  test "keeps a Console-only execution claim unverified and append-only", context do
    prepared = prepare_boundary(context, "session-console-only", "watermark-console-only")
    assert {:ok, _reserved} = Watermark.reserve(prepared.boundary, prepared.fence, context.storage)
    persist_projection(context, prepared)

    assert {:ok,
            %{
              status: :repair_required,
              missing_side: :jidoka,
              action: :transcript_only_or_abandon,
              exact_resume: false
            }} = Watermark.verify(prepared.watermark_id, prepared.fence, context.storage)

    assert {:error, {:verified_watermark_not_found, prepared.session_id}} ==
             Storage.verified_watermark(prepared.session_id, context.storage)

    assert {:ok, %{state: "repair_required", exact_resume: false}} =
             Watermark.inspect(prepared.watermark_id, context.storage)

    assert {:ok, abandoned} = Watermark.abandon(prepared.watermark_id, prepared.fence, context.storage)
    assert abandoned.state == "abandoned"

    assert {:error, :watermark_abandoned} =
             Watermark.verify(prepared.watermark_id, prepared.fence, context.storage)
  end

  test "rejects mismatched committed data and a stale generation", context do
    mismatched = prepare_boundary(context, "session-mismatch", "watermark-mismatch")
    wrong_digest = "sha256:" <> String.duplicate("f", 64)

    boundary =
      mismatched.boundary
      |> put_in(["jidoka_identity", "value_digest"], wrong_digest)
      |> Map.put("jidoka_digest", wrong_digest)

    assert {:ok, _reserved} = Watermark.reserve(boundary, mismatched.fence, context.storage)
    persist_checkpoint(context, mismatched)
    persist_projection(context, mismatched)

    assert {:ok,
            %{
              status: :repair_required,
              missing_side: :jidoka,
              reason: {:watermark_receipt_mismatch, "checkpoint", _target}
            }} = Watermark.verify(mismatched.watermark_id, mismatched.fence, context.storage)

    stale = prepare_boundary(context, "session-stale", "watermark-stale")
    assert {:ok, _reserved} = Watermark.reserve(stale.boundary, stale.fence, context.storage)
    persist_checkpoint(context, stale)
    persist_projection(context, stale)

    assert {:ok, newer} =
             Generation.claim(
               stale.session_id,
               context.storage ++
                 [
                   expected_generation: 1,
                   owner_instance_id: "new-owner",
                   operation_id: "new-generation"
                 ]
             )

    assert newer.generation == 2

    assert {:error, :stale_watermark_generation} =
             Watermark.verify(stale.watermark_id, stale.fence, context.storage)
  end

  test "allows declared Console-only tails and rejects a later execution claim", context do
    allowed = prepare_boundary(context, "session-tail-allowed", "watermark-tail-allowed")
    assert {:ok, _reserved} = Watermark.reserve(allowed.boundary, allowed.fence, context.storage)
    persist_checkpoint(context, allowed)
    persist_projection(context, allowed)
    append_tail(context, allowed, "input_admitted")

    assert {:ok, %{status: :verified, exact_resume: true}} =
             Watermark.verify(allowed.watermark_id, allowed.fence, context.storage)

    denied = prepare_boundary(context, "session-tail-denied", "watermark-tail-denied")
    assert {:ok, first} = Watermark.reserve(denied.boundary, denied.fence, context.storage)
    assert {:ok, duplicate} = Watermark.reserve(denied.boundary, denied.fence, context.storage)
    assert first.record_digest == duplicate.record_digest
    assert duplicate.duplicate

    persist_checkpoint(context, denied)
    persist_projection(context, denied)
    append_tail(context, denied, "run_started")

    assert {:ok,
            %{
              status: :repair_required,
              missing_side: :console_tail,
              reason: :watermark_execution_tail_present,
              exact_resume: false
            }} = Watermark.verify(denied.watermark_id, denied.fence, context.storage)
  end

  test "retains the verified index across restart and makes transitions immutable", context do
    prepared = prepare_boundary(context, "session-restart", "watermark-restart")
    assert {:ok, _reserved} = Watermark.reserve(prepared.boundary, prepared.fence, context.storage)
    persist_checkpoint(context, prepared)
    persist_projection(context, prepared)
    assert {:ok, %{status: :verified}} = Watermark.verify(prepared.watermark_id, prepared.fence, context.storage)

    Supervisor.stop(context.supervisor)
    database = Path.join(context.root, "state/sessions/v1/console.sqlite3")
    assert {:ok, conn} = Exqlite.Sqlite3.open(database)

    assert {:error, _reason} =
             Exqlite.Sqlite3.execute(conn, "UPDATE watermark_transitions SET state='abandoned'")

    assert :ok = Exqlite.Sqlite3.close(conn)
    assert {:ok, restarted} = StorageSupervisor.start_link(context.names)

    assert {:ok, latest} = Storage.verified_watermark(prepared.session_id, context.storage)
    assert latest.watermark_id == prepared.watermark_id
    assert {:ok, %{integrity: :ok}} = Storage.inspect_store(context.storage)
    Supervisor.stop(restarted)
  end

  defp prepare_boundary(context, session_id, watermark_id) do
    fence = claim_generation(session_id, context.storage)
    source = session(session_id)
    {:ok, mapping} = SessionJidoka.session_mapping(session_id)
    request = JidokaTurn.Request.new!(input: "Continue", request_id: "request-#{watermark_id}")
    store = {SQLite, pid: context.writer}
    put_operation_id = "jidoka-put-#{watermark_id}"

    put_store =
      {SQLite,
       [
         pid: context.writer,
         operation_id: put_operation_id,
         console_fence: operation_fence(fence, put_operation_id)
       ]}

    assert {:ok, _source} = JidokaStore.put_session(put_store, source)

    claim_operation_id = "jidoka-claim-#{watermark_id}"

    assert {:ok, claimed} =
             JidokaStore.claim_session(store, session_id, request,
               operation_id: claim_operation_id,
               console_fence: operation_fence(fence, claim_operation_id),
               clock: fn -> 100 end,
               lease_ttl_ms: 50,
               owner_id: "worker-#{watermark_id}",
               id_generator: fn "lease" -> "lease-#{watermark_id}" end
             )

    snapshot = snapshot(claimed, "snapshot-#{watermark_id}")

    {:ok, checkpointed} =
      SessionJidoka.checkpoint_transition(mapping, claimed, "lease-#{watermark_id}", snapshot,
        clock: fn -> 110 end,
        lease_ttl_ms: 50
      )

    {:ok, encoded} = JidokaValue.encode(checkpointed)
    checkpoint_operation_id = "jidoka-checkpoint-#{watermark_id}"

    jidoka_identity = %{
      "session_id" => session_id,
      "revision" => checkpointed.revision,
      "request_id" => request.request_id,
      "lease_id" => "lease-#{watermark_id}",
      "snapshot_id" => snapshot.snapshot_id,
      "operation_id" => checkpoint_operation_id,
      "value_digest" => encoded.digest
    }

    assert {:ok, %{boundary: boundary, event: event}} =
             Watermark.prepare_projection(watermark_id, jidoka_identity, fence, context.storage)

    %{
      session_id: session_id,
      watermark_id: watermark_id,
      fence: fence,
      source: source,
      request: request,
      snapshot: snapshot,
      checkpointed: checkpointed,
      checkpoint_operation_id: checkpoint_operation_id,
      boundary: boundary,
      event: event
    }
  end

  defp persist_checkpoint(context, prepared) do
    store = {SQLite, pid: context.writer}

    assert {:ok, checkpointed} =
             JidokaStore.checkpoint_session(
               store,
               prepared.session_id,
               "lease-#{prepared.watermark_id}",
               prepared.snapshot,
               operation_id: prepared.checkpoint_operation_id,
               console_fence: operation_fence(prepared.fence, prepared.checkpoint_operation_id),
               clock: fn -> 110 end,
               lease_ttl_ms: 50
             )

    assert checkpointed == prepared.checkpointed
  end

  defp persist_projection(context, prepared) do
    operation_id = prepared.boundary["console_identity"]["operation_id"]

    assert {:ok, result} =
             Storage.append_event(
               prepared.event,
               %{session_id: prepared.session_id, sequence: 1},
               context.storage ++
                 [operation_id: operation_id, fence: operation_fence(prepared.fence, operation_id)]
             )

    assert result.chain_digest == prepared.boundary["console_digest"]
  end

  defp append_tail(context, prepared, type) do
    attrs = %{
      "type" => type,
      "id" => "tail-#{type}-#{prepared.watermark_id}",
      "session_id" => prepared.session_id,
      "sequence" => 2,
      "durability" => "process",
      "sensitivity" => "public",
      "origin" => %{"kind" => "session", "actor_id" => prepared.session_id},
      "trust" => %{"evidence" => "tail-test", "policy" => "canonical"},
      "identities" => [
        %{
          "kind" => "session",
          "id" => prepared.session_id,
          "session_id" => prepared.session_id,
          "generation" => prepared.fence.generation,
          "owner_instance_id" => prepared.fence.owner_instance_id
        }
      ]
    }

    attrs =
      case type do
        "input_admitted" ->
          Map.merge(attrs, %{
            "input_id" => "input-tail",
            "client_id" => "client-tail",
            "queue" => "follow_up",
            "items" => []
          })

        "run_started" ->
          Map.merge(attrs, %{"run_id" => "run-tail", "turn_id" => "turn-tail"})
      end

    assert {:ok, event} = Event.classify(attrs)
    operation_id = "tail-#{type}-#{prepared.watermark_id}"

    assert {:ok, _result} =
             Storage.append_event(
               event,
               %{session_id: prepared.session_id, sequence: 2},
               context.storage ++
                 [operation_id: operation_id, fence: operation_fence(prepared.fence, operation_id)]
             )
  end

  defp claim_generation(session_id, storage) do
    assert {:ok, fence} =
             Generation.claim(
               session_id,
               storage ++
                 [
                   expected_generation: 0,
                   owner_instance_id: "owner-#{session_id}",
                   operation_id: "generation-claim-#{session_id}"
                 ]
             )

    fence
  end

  defp operation_fence(fence, operation_id), do: Generation.for_operation(fence, operation_id)

  defp session(session_id) do
    {:ok, value} = JidokaData.start(Jido.Console.DefaultAgent.spec(), session_id: session_id)
    value
  end

  defp snapshot(%JidokaData{} = session, snapshot_id) do
    request = List.last(session.requests)

    state =
      JidokaTurn.State.new!(
        spec: session.spec,
        plan: JidokaTurn.Plan.new!(session.spec),
        request: request,
        agent_state: request.agent_state
      )

    JidokaSnapshot.from_turn_state!(state, JidokaTurn.Cursor.after_prompt(), snapshot_id: snapshot_id)
  end

  defp unique(label), do: String.to_atom("watermark-#{label}-#{System.unique_integer([:positive])}")
end
