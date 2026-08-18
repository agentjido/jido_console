defmodule Jido.Console.Session.Store.SQLiteTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Console.Session.Durable.Record
  alias Jido.Console.Session.Store.SQLite
  alias Jidoka.Agent.Spec
  alias Jidoka.Session.{Data, Lease, Store}
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  @digest "sha256:" <> String.duplicate("a", 64)

  setup do
    root = Path.join(System.tmp_dir!(), "jido-sqlite-store-#{System.unique_integer([:positive])}")
    path = Path.join(root, "state/v1/sessions.sqlite3")
    on_exit(fn -> File.rm_rf(root) end)
    %{path: path, root: root}
  end

  test "uses the versioned private Jido path and the pinned direct adapter", %{root: root} do
    assert {:ok, path} = SQLite.default_path(jido_home: root)
    assert path == Path.join(root, "state/sessions/v1/console.sqlite3")
    assert SQLite.dependency_identity() == %{name: :exqlite, version: "0.39.0", license: "MIT"}

    assert SQLite.limits() == %{
             active_sessions: 128,
             canonical_events: 10_000,
             control_reserve_bytes: 167_772_160,
             database_bytes: 1_073_741_824,
             jidoka_value_bytes: 134_217_728,
             normal_bytes: 905_969_664,
             reader_age_ms: 1_000,
             reader_limit: 16,
             reserved_readers: 4,
             session_bytes: 67_108_864
           }

    assert {:ok, pid} = SQLite.start_link(jido_home: root)
    assert {:ok, :durable} = Store.durable_mode(SQLite)
    assert :ok = File.chmod(path, 0o600)
    assert {:ok, %{integrity: :ok, store_format: 1, path: ^path}} = SQLite.inspect_store(pid)

    assert {:ok, %{page_count: pages, page_size: 4_096, normal_bytes_remaining: remaining}} =
             SQLite.page_accounting(pid)

    assert pages > 0
    assert remaining > 0
    GenServer.stop(pid)

    assert {:ok, restarted} = SQLite.start_link(jido_home: root)
    assert {:ok, %{integrity: :ok}} = SQLite.inspect_store(restarted)
    GenServer.stop(restarted)
  end

  test "appends canonical records with identity, order, receipt, and range bounds", %{path: path} do
    {:ok, pid} = SQLite.start_link(path: path)
    first = record(0, "genesis")
    assert {:error, :operation_id_required} = SQLite.append(pid, first)

    assert {:ok, %{record_id: "record-0", sequence: 0, digest: digest}} =
             SQLite.append(pid, first, operation_id: "append-0")

    assert {:ok, %{target_id: "record-0", result_digest: ^digest}} = SQLite.receipt(pid, "append-0")

    assert {:error, {:record_sequence_conflict, "session-fixture", 1, 0}} =
             SQLite.append(pid, first, operation_id: "append-duplicate")

    second = record(1, digest)
    assert {:ok, %{sequence: 1}} = SQLite.append(pid, second, operation_id: "append-1")
    assert {:ok, [first_result]} = SQLite.range(pid, "session-fixture", limit: 1)
    assert first_result.record["record_id"] == "record-0"

    assert {:ok, [second_result]} = SQLite.range(pid, "session-fixture", after: 0, limit: 2)
    assert second_result.record["record_id"] == "record-1"
    assert {:ok, []} = SQLite.range(pid, "session-fixture", max_bytes: 1)
    assert {:error, :invalid_query_bounds} = SQLite.range(pid, "session-fixture", limit: 0)
    assert {:error, :invalid_query_bounds} = SQLite.range(pid, "session-fixture", limit: 1_001)

    sensitive = put_in(first, ["payload", "api_key"], "CANARY_DO_NOT_STORE")
    assert {:error, _reason} = SQLite.append(pid, sensitive, operation_id: "sensitive-record")
    assert {:error, {:operation_not_found, "sensitive-record"}} = SQLite.receipt(pid, "sensitive-record")
  end

  test "persists public Jidoka transitions atomically across reopen", %{path: path} do
    {:ok, pid} = SQLite.start_link(path: path)
    store = {SQLite, pid: pid}
    source = session("sqlite-session")
    request = Turn.Request.new!(input: "Persist", request_id: "request-one")

    assert {:ok, ^source} = Store.put_session(store, source)

    sensitive_request =
      Turn.Request.new!(
        input: "Reject",
        request_id: "request-sensitive",
        metadata: %{"api_key" => "CANARY_DO_NOT_STORE"}
      )

    assert {:error, {:sensitive_value_rejected, %{"redacted" => true}}} =
             Store.claim_session(store, source.session_id, sensitive_request, operation_id: "sensitive-claim")

    assert {:ok, %Data{revision: 0, status: :new, lease: nil}} = Store.get_session(store, source.session_id)
    assert {:error, {:operation_not_found, "sensitive-claim"}} = SQLite.receipt(pid, "sensitive-claim")

    assert {:ok, %Data{revision: 1, lease: %Lease{lease_id: "lease-one"}} = claimed} =
             Store.claim_session(store, source.session_id, request,
               clock: fn -> 100 end,
               lease_ttl_ms: 50,
               owner_id: "worker-one",
               id_generator: fn "lease" -> "lease-one" end
             )

    assert {:error, {:session_already_running, "sqlite-session"}} =
             Store.claim_session(store, source.session_id, request,
               clock: fn -> 101 end,
               lease_ttl_ms: 50,
               owner_id: "worker-two",
               id_generator: fn "lease" -> "lease-two" end,
               operation_id: "stale-claim"
             )

    durable_snapshot = snapshot(claimed, "snapshot-one")

    assert {:ok, %Data{revision: 2}} =
             Store.checkpoint_session(store, source.session_id, "lease-one", durable_snapshot,
               clock: fn -> 110 end,
               lease_ttl_ms: 50
             )

    assert {:ok, %Data{revision: 3, lease: %Lease{expires_at_ms: 170}}} =
             Store.renew_session(store, source.session_id, "lease-one",
               clock: fn -> 120 end,
               lease_ttl_ms: 50
             )

    GenServer.stop(pid)
    assert {:ok, restarted} = SQLite.start_link(path: path)
    restarted_store = {SQLite, pid: restarted}

    assert {:error, {:session_not_found, "missing-session"}} =
             Store.get_session(restarted_store, "missing-session")

    assert {:error, :invalid_query_bounds} = SQLite.list_sessions(pid: restarted, limit: 0)

    assert {:ok, %Data{revision: 3, lease: %Lease{lease_id: "lease-one"}}} =
             Store.get_session(restarted_store, source.session_id)

    assert {:ok, %Data{revision: 4, lease: %Lease{lease_id: "lease-two"}} = recovered} =
             Store.recover_session(restarted_store, source.session_id,
               clock: fn -> 170 end,
               lease_ttl_ms: 50,
               owner_id: "worker-two",
               id_generator: fn "lease" -> "lease-two" end
             )

    assert {:error, {:stale_session_lease, "sqlite-session", "lease-one"}} =
             Store.commit_session(
               restarted_store,
               source.session_id,
               "lease-one",
               Data.put_error(recovered, :stale),
               clock: fn -> 171 end
             )

    assert {:ok, %Data{revision: 5, lease: nil, status: :error}} =
             Store.commit_session(
               restarted_store,
               source.session_id,
               "lease-two",
               Data.put_error(recovered, :recovered),
               clock: fn -> 171 end
             )

    assert {:ok, [%Data{session_id: "sqlite-session"}]} = Store.list_sessions(restarted_store)
    assert {:ok, %{integrity: :ok}} = SQLite.inspect_store(restarted)
  end

  test "detects row corruption and incompatible metadata", %{path: path} do
    {:ok, pid} = SQLite.start_link(path: path)
    assert {:ok, _receipt} = SQLite.append(pid, record(0, "genesis"), operation_id: "append-corrupt")
    GenServer.stop(pid)

    {:ok, conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(conn, "UPDATE records SET digest='sha256:bad'")
    :ok = Sqlite3.close(conn)

    {:ok, corrupted} = SQLite.start_link(path: path)
    assert {:error, {:record_integrity_failed, "record-0"}} = SQLite.inspect_store(corrupted)
    GenServer.stop(corrupted)

    {:ok, conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(conn, "UPDATE store_metadata SET value='2' WHERE key='store_format'")
    :ok = Sqlite3.close(conn)

    Process.flag(:trap_exit, true)

    assert {:error, {:incompatible_store_metadata, "store_format", "1", [["2"]]}} =
             SQLite.start_link(path: path)
  end

  test "rejects invalid and unsafe store paths", %{root: root} do
    Process.flag(:trap_exit, true)
    assert {:error, {:invalid_sqlite_store_path, ""}} = SQLite.start_link(path: "")

    unsafe = Path.join(root, "unsafe.sqlite3")
    File.mkdir_p!(root)
    File.write!(unsafe, "not a database")
    File.chmod!(unsafe, 0o644)

    assert {:error, {:unsafe_permissions, ^unsafe, _mode}} = SQLite.start_link(path: unsafe)
  end

  defp record(sequence, prior) do
    Record.new(
      "input_receipt",
      %{
        "operation_id" => "operation-#{sequence}",
        "idempotency_key" => "idempotency-#{sequence}",
        "payload_digest" => @digest,
        "input_id" => "input-#{sequence}",
        "admission_state" => "accepted"
      },
      record_id: "record-#{sequence}",
      scope_id: "session-fixture",
      generation: 1,
      sequence: sequence,
      prior_record_digest: prior
    )
  end

  defp session(session_id) do
    spec =
      Spec.new!(
        id: "sqlite_store_agent",
        instructions: "Test the durable SQLite store.",
        model: %{provider: :test, id: "model"}
      )

    {:ok, session} = Data.start(spec, session_id: session_id)
    session
  end

  defp snapshot(%Data{} = session, snapshot_id) do
    request = List.last(session.requests)

    Turn.State.new!(
      spec: session.spec,
      plan: Turn.Plan.new!(session.spec),
      request: request,
      agent_state: request.agent_state
    )
    |> Snapshot.from_turn_state!(Turn.Cursor.after_prompt(), snapshot_id: snapshot_id)
  end
end
