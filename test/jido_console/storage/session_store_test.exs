defmodule Jido.Console.Storage.SessionStoreTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Console.Storage
  alias Jido.Console.Storage.SQLite
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor
  alias Jidoka.Agent
  alias Jidoka.Session.Data
  alias Jidoka.Session.Lease
  alias Jidoka.Session.Store
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  setup do
    root = Path.join(System.tmp_dir!(), "jido-session-store-#{System.unique_integer([:positive])}")

    opts = [
      name: unique(:supervisor),
      lock: unique(:lock),
      writer: unique(:writer),
      jido_home: root
    ]

    assert {:ok, supervisor} = StorageSupervisor.start_link(opts)
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, opts: opts, supervisor: supervisor, store: Storage.session_store(writer: opts[:writer])}
  end

  test "implements the complete durable Jidoka store contract", context do
    if function_exported?(Store, :durable_mode, 1) do
      assert {:ok, :durable} = apply(Store, :durable_mode, [SQLite])
    else
      assert Enum.all?(
               [
                 claim_session: 3,
                 claim_resume: 2,
                 recover_session: 2,
                 checkpoint_session: 4,
                 commit_session: 4,
                 renew_session: 3
               ],
               fn {name, arity} -> function_exported?(SQLite, name, arity) end
             )
    end

    session = session("store-contract")
    assert {:ok, ^session} = Store.put_session(context.store, session)
    assert {:ok, ^session} = Store.get_session(context.store, session.session_id)
    assert {:ok, [^session]} = Store.list_sessions(context.store)
  end

  test "serializes concurrent claims with one winner", context do
    session = session("claim-race")
    assert {:ok, ^session} = Store.put_session(context.store, session)

    requests = [
      Turn.Request.new!(input: "first", request_id: "claim-first"),
      Turn.Request.new!(input: "second", request_id: "claim-second")
    ]

    results =
      requests
      |> Enum.map(fn request ->
        Task.async(fn ->
          Store.claim_session(context.store, session.session_id, request,
            clock: fn -> 100 end,
            lease_ttl_ms: 50
          )
        end)
      end)
      |> Task.await_many()

    assert 1 == Enum.count(results, &match?({:ok, %Data{status: :running}}, &1))

    assert 1 ==
             Enum.count(
               results,
               &match?({:error, {:session_already_running, "claim-race"}}, &1)
             )
  end

  test "applies checkpoint, renewal, recovery, and commit transitions atomically", context do
    source = session("lease-lifecycle")
    request = Turn.Request.new!(input: "run", request_id: "lease-request")
    assert {:ok, ^source} = Store.put_session(context.store, source)

    assert {:ok, %Data{revision: 1, lease: %Lease{lease_id: "lease-one"}} = claimed} =
             Store.claim_session(context.store, source.session_id, request,
               clock: fn -> 100 end,
               lease_ttl_ms: 50,
               owner_id: "worker-one",
               id_generator: id_generator("lease-one")
             )

    snapshot = snapshot(claimed, "snapshot-one")

    assert {:ok, %Data{revision: 2, lease: %Lease{expires_at_ms: 160}}} =
             Store.checkpoint_session(context.store, source.session_id, "lease-one", snapshot,
               clock: fn -> 110 end,
               lease_ttl_ms: 50
             )

    assert {:ok, %Data{revision: 3, lease: %Lease{expires_at_ms: 170}}} =
             Store.renew_session(context.store, source.session_id, "lease-one",
               clock: fn -> 120 end,
               lease_ttl_ms: 50
             )

    assert {:error, {:session_lease_active, "lease-lifecycle", "worker-one", 170}} =
             Store.recover_session(context.store, source.session_id, clock: fn -> 169 end)

    assert {:ok, %Data{revision: 4, lease: %Lease{lease_id: "lease-two"}} = recovered} =
             Store.recover_session(context.store, source.session_id,
               clock: fn -> 170 end,
               lease_ttl_ms: 50,
               owner_id: "worker-two",
               id_generator: id_generator("lease-two")
             )

    assert {:error, {:stale_session_lease, "lease-lifecycle", "lease-one"}} =
             Store.commit_session(
               context.store,
               source.session_id,
               "lease-one",
               Data.put_error(claimed, :stale),
               clock: fn -> 171 end
             )

    assert {:ok, %Data{revision: 5, status: :error, lease: nil, error: :interrupted} = committed} =
             Store.commit_session(
               context.store,
               source.session_id,
               "lease-two",
               Data.put_error(recovered, :interrupted),
               clock: fn -> 171 end
             )

    assert {:ok, ^committed} = Store.get_session(context.store, source.session_id)
  end

  test "claims a stored hibernated session for resume", context do
    source = session("resume-lifecycle")
    request = Turn.Request.new!(input: "pause", request_id: "resume-request")
    assert {:ok, ^source} = Store.put_session(context.store, source)

    assert {:ok, %Data{lease: %Lease{lease_id: "resume-lease"}} = claimed} =
             Store.claim_session(context.store, source.session_id, request,
               clock: fn -> 100 end,
               lease_ttl_ms: 50,
               id_generator: id_generator("resume-lease")
             )

    snapshot = snapshot(claimed, "resume-snapshot")
    hibernated = Data.put_snapshot(claimed, snapshot)

    assert {:ok, %Data{status: :hibernated, lease: nil}} =
             Store.commit_session(
               context.store,
               source.session_id,
               "resume-lease",
               hibernated,
               clock: fn -> 110 end
             )

    assert {:ok, %Data{status: :running, lease: %Lease{lease_id: "continued-lease"}}} =
             Store.claim_resume(context.store, source.session_id,
               clock: fn -> 120 end,
               lease_ttl_ms: 50,
               id_generator: id_generator("continued-lease")
             )
  end

  test "rejects malformed session bytes before they enter a transition", context do
    source = session("corrupt-session")
    assert {:ok, ^source} = Store.put_session(context.store, source)

    path = Path.join(context.root, "state/console.sqlite3")
    assert {:ok, conn} = Sqlite3.open(path)

    assert {:ok, statement} =
             Sqlite3.prepare(
               conn,
               "UPDATE sessions SET encoded_bytes=?, session_term=? WHERE session_id=?"
             )

    bytes = :erlang.term_to_binary({:wrong_codec, 1, source})
    assert :ok = Sqlite3.bind(statement, [byte_size(bytes), {:blob, bytes}, source.session_id])
    assert :done = Sqlite3.step(conn, statement)
    assert :ok = Sqlite3.release(conn, statement)
    assert :ok = Sqlite3.close(conn)

    assert {:error, {:session_integrity_failed, "corrupt-session", :invalid_session_codec}} =
             Store.get_session(context.store, source.session_id)
  end

  test "rejects unsupported codecs and damaged indexed session fields", context do
    unsupported = session("unsupported-codec")
    damaged = session("damaged-index")
    assert {:ok, ^unsupported} = Store.put_session(context.store, unsupported)
    assert {:ok, ^damaged} = Store.put_session(context.store, damaged)

    path = Path.join(context.root, "state/console.sqlite3")
    assert {:ok, conn} = Sqlite3.open(path)
    bytes = :erlang.term_to_binary({:jido_console_session, 99, unsupported})

    assert :ok =
             update(conn, "UPDATE sessions SET encoded_bytes=?, session_term=? WHERE session_id=?", [
               byte_size(bytes),
               {:blob, bytes},
               unsupported.session_id
             ])

    assert :ok = update(conn, "UPDATE sessions SET status='running' WHERE session_id=?", [damaged.session_id])
    assert :ok = Sqlite3.close(conn)

    assert {:error, {:session_integrity_failed, "unsupported-codec", {:unsupported_session_codec, 99}}} =
             Store.get_session(context.store, unsupported.session_id)

    assert {:error, {:session_integrity_failed, "damaged-index", :indexed_fields}} =
             Store.get_session(context.store, damaged.session_id)
  end

  defp session(id) do
    {:ok, session} = Data.start(spec(), session_id: id)
    session
  end

  defp snapshot(%Data{} = session, snapshot_id) do
    request = List.last(session.requests)
    plan = Turn.Plan.new!(session.spec)

    Turn.State.new!(
      spec: session.spec,
      plan: plan,
      request: request,
      agent_state: request.agent_state
    )
    |> Snapshot.from_turn_state!(Turn.Cursor.after_prompt(), snapshot_id: snapshot_id)
  end

  defp spec do
    Agent.Spec.new!(
      id: "session-store-agent",
      instructions: "Test session transitions.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp id_generator(id), do: fn "lease" -> id end
  defp unique(label), do: String.to_atom("#{label}-#{System.unique_integer([:positive])}")

  defp update(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql),
         :ok <- Sqlite3.bind(statement, params),
         :done <- Sqlite3.step(conn, statement) do
      Sqlite3.release(conn, statement)
    end
  end
end
