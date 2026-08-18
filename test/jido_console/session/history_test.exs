defmodule Jido.Console.Session.HistoryTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Console.Digest
  alias Jido.Console.Session.Durable.{CanonicalJSON, Record}
  alias Jido.Console.Session.{Event, Generation, History, Identity, Reducer, State}
  alias Jido.Console.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "jido-history-#{System.unique_integer([:positive])}")

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

  test "commits exact events, rejects conflicts, and rebuilds after reopen", context do
    session_id = "session-history"
    {:ok, fence} = claim(session_id, context.storage)
    identity = session_identity(session_id, fence)

    first = event(identity, "run_started", 1)
    {:ok, state_one} = Reducer.apply_event(State.new(session_id), first)

    assert {:ok, first_result} = History.append(first, state_one, fence, context.storage)
    assert first_result.sequence == 1
    assert first_result.duplicate == false
    assert first_result.snapshot == :not_due

    assert {:ok, duplicate} = History.append(first, state_one, fence, context.storage)
    assert duplicate.duplicate == true

    conflicting = put_in(first, ["payload", "trust", "evidence"], "changed")
    {:ok, conflicting_state} = Reducer.apply_event(State.new(session_id), conflicting)

    assert {:error, {:canonical_event_conflict, event_id}} =
             History.append(conflicting, conflicting_state, fence, context.storage)

    assert event_id == first["id"]

    second = event(identity, "run_completed", 2)
    {:ok, state_two} = Reducer.apply_event(state_one, second)
    assert {:ok, second_result} = History.append(second, state_two, fence, context.storage)
    assert is_map(second_result.snapshot)
    assert second_result.snapshot.source_sequence == 2

    assert {:ok, head} = Storage.history_head(session_id, context.storage)
    assert head.sequence == 2

    Supervisor.stop(context.supervisor)
    assert {:ok, restarted} = Jido.Console.Storage.Supervisor.start_link(context.names)

    assert {:ok, rebuilt} = History.rebuild(session_id, context.storage)
    assert rebuilt.state.sequence == 2
    assert rebuilt.state.active_run == state_two.active_run
    assert rebuilt.state.queues == state_two.queues
    assert rebuilt.suffix_events == 0
    assert rebuilt.snapshot != nil

    Supervisor.stop(restarted)
    path = Path.join(context.root, "state/sessions/v1/console.sqlite3")
    {:ok, conn} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               conn,
               "UPDATE history_heads SET chain_digest='sha256:#{String.duplicate("0", 64)}' WHERE scope_id='#{session_id}'"
             )

    assert :ok = Sqlite3.close(conn)
    assert {:ok, _restarted} = Jido.Console.Storage.Supervisor.start_link(context.names)
    assert {:error, :canonical_history_head_mismatch} = History.rebuild(session_id, context.storage)
  end

  test "uses an earlier valid snapshot when the latest derived snapshot is corrupt", context do
    session_id = "session-corrupt-snapshot"
    {:ok, fence} = claim(session_id, context.storage)
    identity = session_identity(session_id, fence)

    first = event(identity, "run_started", 1)
    {:ok, state_one} = Reducer.apply_event(State.new(session_id), first)
    assert {:ok, _result} = History.append(first, state_one, fence, context.storage)
    assert {:ok, first_snapshot} = History.snapshot(state_one, fence, "manual", context.storage)
    assert {:ok, duplicate_snapshot} = History.snapshot(state_one, fence, "manual", context.storage)
    assert duplicate_snapshot.snapshot_id == first_snapshot.snapshot_id
    assert duplicate_snapshot.duplicate == true

    second = event(identity, "run_completed", 2)
    {:ok, state_two} = Reducer.apply_event(state_one, second)
    assert {:ok, %{snapshot: second_snapshot}} = History.append(second, state_two, fence, context.storage)
    refute first_snapshot.snapshot_id == second_snapshot.snapshot_id

    Supervisor.stop(context.supervisor)
    path = Path.join(context.root, "state/sessions/v1/console.sqlite3")
    {:ok, conn} = Sqlite3.open(path)

    assert :ok =
             Sqlite3.execute(
               conn,
               "UPDATE semantic_snapshots SET snapshot=x'00' WHERE snapshot_id='#{second_snapshot.snapshot_id}'"
             )

    assert {:error, _reason} =
             Sqlite3.execute(
               conn,
               "UPDATE records SET digest='sha256:changed' WHERE record_type='canonical_console_event'"
             )

    assert :ok = Sqlite3.close(conn)
    assert {:ok, _restarted} = Jido.Console.Storage.Supervisor.start_link(context.names)

    assert {:ok, rebuilt} = History.rebuild(session_id, context.storage)
    assert rebuilt.snapshot == first_snapshot.snapshot_id
    assert rebuilt.suffix_events == 1
    assert rebuilt.state.sequence == 2
    assert rebuilt.state.active_run == nil
  end

  test "rejects gaps, cross-session state, and stale generation fences without mutation", context do
    session_id = "session-invalid-history"
    {:ok, fence} = claim(session_id, context.storage)
    identity = session_identity(session_id, fence)
    gap = event(identity, "run_started", 2)

    assert {:ok, gap_state} = Reducer.apply_event(%{State.new(session_id) | sequence: 1}, gap)

    assert {:error, {:canonical_event_sequence_conflict, ^session_id, 1, 2}} =
             History.append(gap, gap_state, fence, context.storage)

    first = event(identity, "run_started", 1)
    {:ok, state} = Reducer.apply_event(State.new(session_id), first)

    wrong_generation =
      update_in(first, ["payload", "identities"], fn identities ->
        Enum.map(identities, &Map.put(&1, "generation", 2))
      end)

    {:ok, wrong_state} = Reducer.apply_event(State.new(session_id), wrong_generation)

    assert {:error, :event_generation_mismatch} =
             History.append(wrong_generation, wrong_state, fence, context.storage)

    assert {:error, :cross_session_history} =
             History.append(first, %{state | session_id: "other-session"}, fence, context.storage)

    assert {:ok, _first_result} = History.append(first, state, fence, context.storage)

    collision = Map.put(first, "id", "event-sequence-collision")
    {:ok, collision_state} = Reducer.apply_event(State.new(session_id), collision)

    assert {:error, {:canonical_event_sequence_conflict, ^session_id, 2, 1}} =
             History.append(collision, collision_state, fence, context.storage)

    assert {:error, :invalid_history_bounds} =
             Storage.history_suffix(session_id, context.storage ++ [max_bytes: 0])

    assert {:ok, newer} =
             Generation.claim(
               session_id,
               context.storage ++
                 [expected_generation: 1, owner_instance_id: "owner-new", operation_id: "claim-new"]
             )

    assert newer.generation == 2

    assert {:error, {:stale_generation, ^session_id, 1, 2}} =
             History.append(first, state, fence, context.storage)

    assert {:ok, %{sequence: 1}} = Storage.history_head(session_id, context.storage)
  end

  test "creates a snapshot at a projected hibernation boundary", context do
    session_id = "session-hibernation-snapshot"
    {:ok, fence} = claim(session_id, context.storage)
    identity = session_identity(session_id, fence)

    hibernated =
      event(identity, "run_progress", 1, %{
        summary: %{"event" => "turn_hibernated", "status" => "hibernated"}
      })

    {:ok, state} = Reducer.apply_event(State.new(session_id), hibernated)
    assert {:ok, %{snapshot: snapshot}} = History.append(hibernated, state, fence, context.storage)
    assert snapshot.reason == "hibernation"
    assert snapshot.source_sequence == 1
  end

  @tag timeout: 120_000
  test "creates an interval snapshot at exactly 500 suffix events", context do
    session_id = "session-interval-snapshot"
    {:ok, fence} = claim(session_id, context.storage)
    identity = session_identity(session_id, fence)

    {_state, final_result} =
      Enum.reduce(1..500, {State.new(session_id), nil}, fn sequence, {state, _result} ->
        next_event = event(identity, "model_delta", sequence)
        {:ok, next_state} = Reducer.apply_event(state, next_event)
        {:ok, result} = History.append(next_event, next_state, fence, context.storage)

        if sequence < 500, do: assert(result.snapshot == :not_due)
        {next_state, result}
      end)

    assert final_result.snapshot.reason == "interval"
    assert final_result.snapshot.source_sequence == 500
    assert final_result.snapshot.encoded_bytes <= 1_048_576

    assert {:ok, %{sequence: 500, suffix_events: 0, suffix_bytes: 0}} =
             Storage.history_head(session_id, context.storage)
  end

  test "requires a snapshot when a rebuild suffix exceeds 1,000 events", context do
    session_id = "session-bounded-suffix"
    identity = Identity.new!(:session, id: session_id, generation: 1, owner_instance_id: "owner-one")
    Supervisor.stop(context.supervisor)
    path = Path.join(context.root, "state/sessions/v1/console.sqlite3")
    {:ok, conn} = Sqlite3.open(path)

    assert :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE")

    {:ok, record_statement} =
      Sqlite3.prepare(
        conn,
        "INSERT INTO records(record_id,scope_id,generation,sequence,record_type,prior_digest,digest,encoded_bytes,json) VALUES(?,?,?,?,?,?,?,?,?)"
      )

    {:ok, index_statement} =
      Sqlite3.prepare(
        conn,
        "INSERT INTO canonical_event_index(event_id,scope_id,sequence,record_id,event_digest) VALUES(?,?,?,?,?)"
      )

    final_digest =
      Enum.reduce(1..1_001, "genesis", fn sequence, prior ->
        canonical_event = event(identity, "model_delta", sequence)
        {:ok, encoded} = durable_record(canonical_event, sequence, prior)
        {:ok, event_bytes} = CanonicalJSON.encode(canonical_event)

        assert :ok =
                 Sqlite3.bind(record_statement, [
                   canonical_event["id"],
                   session_id,
                   1,
                   sequence,
                   "canonical_console_event",
                   prior,
                   encoded.digest,
                   encoded.encoded_bytes,
                   {:blob, encoded.bytes}
                 ])

        assert :done = Sqlite3.step(conn, record_statement)
        assert :ok = Sqlite3.reset(record_statement)

        assert :ok =
                 Sqlite3.bind(index_statement, [
                   canonical_event["id"],
                   session_id,
                   sequence,
                   canonical_event["id"],
                   Digest.portable(event_bytes)
                 ])

        assert :done = Sqlite3.step(conn, index_statement)
        assert :ok = Sqlite3.reset(index_statement)
        encoded.digest
      end)

    assert :ok = Sqlite3.release(conn, record_statement)
    assert :ok = Sqlite3.release(conn, index_statement)

    assert :ok =
             Sqlite3.execute(
               conn,
               "INSERT INTO history_heads(scope_id,generation,sequence,record_id,chain_digest,suffix_events,suffix_bytes) VALUES('#{session_id}',1,1001,'event-#{session_id}-1001','#{final_digest}',1001,8388608)"
             )

    assert :ok = Sqlite3.execute(conn, "COMMIT")
    assert :ok = Sqlite3.close(conn)
    assert {:ok, _restarted} = Jido.Console.Storage.Supervisor.start_link(context.names)

    assert {:error, :snapshot_rebuild_required} = History.rebuild(session_id, context.storage)
  end

  defp durable_record(canonical_event, sequence, prior) do
    payload = canonical_event["payload"]
    {:ok, origin} = CanonicalJSON.encode(payload["origin"])
    {:ok, trust} = CanonicalJSON.encode(payload["trust"])

    "canonical_console_event"
    |> Record.new(
      %{
        "event_id" => canonical_event["id"],
        "sequence" => sequence,
        "event_class" => canonical_event["type"],
        "origin" => origin,
        "trust" => trust,
        "sensitivity" => payload["sensitivity"],
        "event" => canonical_event
      },
      record_id: canonical_event["id"],
      scope_id: canonical_event["session_id"],
      generation: 1,
      sequence: sequence,
      prior_record_digest: prior
    )
    |> Record.encode()
  end

  defp claim(session_id, storage) do
    Generation.claim(
      session_id,
      storage ++
        [expected_generation: 0, owner_instance_id: "owner-one", operation_id: "claim-one"]
    )
  end

  defp session_identity(session_id, fence) do
    Identity.new!(:session,
      id: session_id,
      generation: fence.generation,
      owner_instance_id: fence.owner_instance_id
    )
  end

  defp event(identity, type, sequence, extra \\ %{}) do
    {:ok, value} =
      %{
        type: type,
        id: "event-#{identity.id}-#{sequence}",
        session_id: identity.id,
        sequence: sequence,
        durability: "process",
        sensitivity: "public",
        origin: %{kind: "session", actor_id: identity.id},
        trust: %{evidence: "test", policy: "session-owner"},
        identities: [Identity.to_protocol(identity)],
        run_id: "run-#{identity.id}"
      }
      |> Map.merge(extra)
      |> Event.classify()

    value
  end

  defp unique(label), do: String.to_atom("jido-history-#{label}-#{System.unique_integer([:positive])}")
end
