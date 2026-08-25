defmodule Jido.Console.Storage.ThreadEventStoreTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Console.Digest
  alias Jido.Console.Session.Event
  alias Jido.Console.Storage
  alias Jido.Console.Storage.SQLite
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor
  alias Jidoka.Agent
  alias Jidoka.Session.Data
  alias Jidoka.Session.Store

  defmodule SilentWriter do
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, nil}
    def handle_call(_message, _from, state), do: {:noreply, state}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "jido-thread-events-#{System.unique_integer([:positive])}")

    opts = [
      name: unique(:supervisor),
      lock: unique(:lock),
      writer: unique(:writer),
      jido_home: root
    ]

    assert {:ok, supervisor} = StorageSupervisor.start_link(opts)
    store_opts = [writer: opts[:writer], deadline: 5_000]
    store = Storage.session_store(store_opts)
    assert {:ok, _session} = Store.put_session(store, session("thread-one"))

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, opts: opts, store_opts: store_opts, store: store, supervisor: supervisor}
  end

  test "appends an ordered lifecycle and reads it by thread and request", context do
    queued = event("queued-1", "item-1", "request-1", "prompt_queued", %{"input" => "hello"})
    started = event("started-1", "item-1", "request-1", "prompt_started")
    closed = event("closed-1", "item-1", "request-1", "prompt_succeeded", %{"content" => "hi"}, 3)

    assert {:ok, %{event: %{sequence: 1}, duplicate: false}} =
             Storage.append_thread_event(queued, context.store_opts)

    assert {:ok, %{event: %{sequence: 2}, duplicate: false}} =
             Storage.append_thread_event(started, context.store_opts)

    assert {:ok, %{event: %{sequence: 3}, duplicate: false}} =
             Storage.append_thread_event(closed, context.store_opts)

    assert {:ok, %{events: events, history_truncated?: false}} =
             Storage.thread_events("thread-one", context.store_opts)

    assert Enum.map(events, & &1.type) == ~w(prompt_queued prompt_started prompt_succeeded)
    assert Enum.map(events, & &1.sequence) == [1, 2, 3]
    assert {:ok, []} = Storage.open_thread_items("thread-one", context.store_opts)
    assert {:ok, ^events} = Storage.request_events("thread-one", "request-1", context.store_opts)
    assert {:ok, %{integrity: :ok, thread_events: 3}} = Storage.inspect_store(context.store_opts)
  end

  test "makes same-event retries idempotent and rejects changed data", context do
    original = event("stable-event", "stable-item", "stable-request", "prompt_queued", %{"input" => "same"})

    assert {:ok, %{event: stored, duplicate: false}} =
             Storage.append_thread_event(original, context.store_opts)

    assert {:ok, %{event: ^stored, duplicate: true}} =
             Storage.append_thread_event(original, context.store_opts)

    changed = %{original | payload: %{"input" => "different"}}

    assert {:error, {:event_conflict, "stable-event"}} =
             Storage.append_thread_event(changed, context.store_opts)

    assert {:ok, %{events: [^stored]}} = Storage.thread_events("thread-one", context.store_opts)
  end

  test "rejects contradictory item lifecycles and request identities", context do
    assert {:ok, _result} =
             Storage.append_thread_event(
               event("queued-life", "item-life", "request-life", "prompt_queued"),
               context.store_opts
             )

    assert {:error, {:invalid_thread_event_lifecycle, "item-life", "prompt_started", :request_identity_conflict}} =
             Storage.append_thread_event(
               event("wrong-request", "item-life", "other-request", "prompt_started"),
               context.store_opts
             )

    assert {:ok, _result} =
             Storage.append_thread_event(
               event("started-life", "item-life", "request-life", "prompt_started"),
               context.store_opts
             )

    assert {:error, {:invalid_thread_event_lifecycle, "item-life", "prompt_started", :already_started}} =
             Storage.append_thread_event(
               event("started-again", "item-life", "request-life", "prompt_started"),
               context.store_opts
             )

    assert {:error, {:invalid_thread_event_lifecycle, "item-life", "prompt_removed", :already_started}} =
             Storage.append_thread_event(
               event("remove-started", "item-life", "request-life", "prompt_removed"),
               context.store_opts
             )

    assert {:ok, _result} =
             Storage.append_thread_event(
               event("failed-life", "item-life", "request-life", "prompt_failed"),
               context.store_opts
             )

    assert {:error, {:invalid_thread_event_lifecycle, "item-life", "prompt_interrupted", :already_closed}} =
             Storage.append_thread_event(
               event("close-again", "item-life", "request-life", "prompt_interrupted"),
               context.store_opts
             )
  end

  test "rejects every invalid lifecycle edge and caller-owned storage fields", context do
    assert {:error, :invalid_thread_event} =
             SQLite.append_thread_event(context.opts[:writer], :invalid)

    assert {:error, {:invalid_thread_event_lifecycle, "missing", "prompt_started", :missing_queued}} =
             Storage.append_thread_event(
               event("missing-start", "missing", "missing-request", "prompt_started"),
               context.store_opts
             )

    queued = event("edge-queued", "edge", "edge-request", "prompt_queued")
    assert {:ok, _} = Storage.append_thread_event(queued, context.store_opts)

    assert {:error, {:invalid_thread_event_lifecycle, "edge", "prompt_queued", :already_queued}} =
             Storage.append_thread_event(
               event("edge-queued-again", "edge", "edge-request", "prompt_queued"),
               context.store_opts
             )

    for type <- ["review_presented", "prompt_succeeded", "prompt_cancelled"] do
      assert {:error, {:invalid_thread_event_lifecycle, "edge", ^type, :not_started}} =
               Storage.append_thread_event(
                 event("edge-#{type}", "edge", "edge-request", type),
                 context.store_opts
               )
    end

    assert {:error, :thread_event_storage_fields_forbidden} =
             Storage.append_thread_event(%{queued | sequence: 1, committed_at_ms: 1}, context.store_opts)
  end

  test "exposes direct bounded SQLite inspection operations", context do
    assert %{event_page: 200, event_page_max: 1_000} = SQLite.limits()
    assert {:ok, path} = SQLite.default_path(jido_home: context.root)
    assert String.ends_with?(path, "console.sqlite3")
    assert {:ok, %{sessions: 1}} = SQLite.status(context.opts[:writer])
    assert {:ok, %{integrity: :ok}} = SQLite.inspect_store(context.opts[:writer])
    assert {:ok, []} = SQLite.open_thread_items(context.opts[:writer], "thread-one")
    assert {:ok, []} = SQLite.request_events(context.opts[:writer], "thread-one", "missing")
    assert {:error, :invalid_thread_event_bounds} = SQLite.thread_events(context.opts[:writer], "thread-one", limit: 0)
  end

  test "uses an explicit database path and an injected event clock", context do
    path = Path.join(context.root, "direct.sqlite3")
    writer = unique(:direct_writer)

    assert {:ok, pid} =
             SQLite.start_link(name: writer, path: path, integrity_on_open: false)

    direct_store = Storage.session_store(writer: writer)
    assert {:ok, _session} = Store.put_session(direct_store, session("direct-thread"))

    direct_event =
      %{event("clock-event", "clock-item", "clock-request", "prompt_queued") | session_id: "direct-thread"}

    assert {:ok, %{event: %{committed_at_ms: 123_456}, duplicate: false}} =
             Storage.append_thread_event(direct_event, writer: writer, clock: fn -> 123_456 end)

    GenServer.stop(pid)
    assert File.regular?(path)
  end

  test "rejects invalid and unsafe explicit database paths", context do
    previous = Process.flag(:trap_exit, true)
    unsafe_path = Path.join(context.root, "unsafe.sqlite3")
    File.mkdir_p!(unsafe_path)

    assert {:error, {:invalid_sqlite_store_path, 42}} =
             SQLite.start_link(name: unique(:invalid_path_writer), path: 42)

    assert {:error, {:unsafe_store_file, path, :directory}} =
             SQLite.start_link(name: unique(:unsafe_path_writer), path: unsafe_path)

    assert path == Path.expand(unsafe_path)
    Process.flag(:trap_exit, previous)
  end

  test "distinguishes storage failure from an ambiguous write timeout" do
    queued = event("timeout-event", "timeout-item", "timeout-request", "prompt_queued")
    missing_writer = unique(:missing_writer)

    assert {:error, :storage_unavailable} =
             Storage.append_thread_event(queued, writer: missing_writer, deadline: 10)

    assert {:error, :storage_unavailable} =
             Storage.thread_events("thread-one", writer: missing_writer, deadline: 10)

    assert {:ok, silent_writer} = SilentWriter.start_link()

    assert {:error, {:timeout_unknown, "timeout-event"}} =
             Storage.append_thread_event(queued, writer: silent_writer, deadline: 1)

    assert {:error, :storage_reader_timeout} =
             Storage.thread_events("thread-one", writer: silent_writer, deadline: 1)

    GenServer.stop(silent_writer)
  end

  test "inspection detects sequence and lifecycle corruption", context do
    assert {:ok, _} =
             Storage.append_thread_event(
               event("inspect-event", "inspect-item", "inspect-request", "prompt_queued"),
               context.store_opts
             )

    path = Path.join(context.root, "state/console.sqlite3")
    assert {:ok, conn} = Sqlite3.open(path)
    assert :ok = update(conn, "UPDATE thread_events SET sequence=2 WHERE event_id=?", ["inspect-event"])
    assert :ok = Sqlite3.close(conn)

    assert {:error, {:thread_event_sequence_gap, "thread-one", [2]}} = Storage.inspect_store(context.store_opts)
  end

  test "requires an existing session and keeps concurrent sequences contiguous", context do
    orphan = %{event("orphan", "orphan-item", "orphan-request", "prompt_queued") | session_id: "missing"}

    assert {:error, {:session_not_found, "missing"}} =
             Storage.append_thread_event(orphan, context.store_opts)

    results =
      1..20
      |> Enum.map(fn index ->
        Task.async(fn ->
          Storage.append_thread_event(
            event("event-#{index}", "item-#{index}", "request-#{index}", "prompt_queued"),
            context.store_opts
          )
        end)
      end)
      |> Task.await_many(10_000)

    assert Enum.all?(results, &match?({:ok, %{duplicate: false}}, &1))

    assert {:ok, %{events: events, history_truncated?: false}} =
             Storage.thread_events("thread-one", Keyword.put(context.store_opts, :limit, 50))

    assert Enum.map(events, & &1.sequence) == Enum.to_list(1..20)
    assert {:ok, open} = Storage.open_thread_items("thread-one", context.store_opts)
    assert length(open) == 20
  end

  test "bounds the live history window without hiding open items", context do
    for index <- 1..201 do
      assert {:ok, _result} =
               Storage.append_thread_event(
                 event("window-event-#{index}", "window-item-#{index}", "window-request-#{index}", "prompt_queued"),
                 context.store_opts
               )
    end

    assert {:ok, %{events: events, history_truncated?: true}} =
             Storage.thread_events("thread-one", context.store_opts)

    assert length(events) == 200
    assert hd(events).sequence == 2
    assert List.last(events).sequence == 201

    assert {:ok, %{events: [oldest], history_truncated?: false}} =
             Storage.thread_events(
               "thread-one",
               context.store_opts ++ [before_sequence: 2, limit: 200]
             )

    assert oldest.sequence == 1
    assert {:ok, open} = Storage.open_thread_items("thread-one", context.store_opts)
    assert length(open) == 201
  end

  test "inspection detects damaged canonical event bytes", context do
    assert {:ok, _result} =
             Storage.append_thread_event(
               event("corrupt-event", "corrupt-item", "corrupt-request", "prompt_queued", %{"input" => "safe"}),
               context.store_opts
             )

    path = Path.join(context.root, "state/console.sqlite3")
    assert {:ok, conn} = Sqlite3.open(path)
    damaged = ~s({"input":"bad!"})

    assert {:ok, statement} =
             Sqlite3.prepare(
               conn,
               "UPDATE thread_events SET encoded_bytes=?, payload_json=? WHERE event_id=?"
             )

    assert :ok = Sqlite3.bind(statement, [byte_size(damaged), {:blob, damaged}, "corrupt-event"])
    assert :done = Sqlite3.step(conn, statement)
    assert :ok = Sqlite3.release(conn, statement)
    assert :ok = Sqlite3.close(conn)

    assert {:error, {:thread_event_integrity_failed, "corrupt-event", :payload_digest}} =
             Storage.inspect_store(context.store_opts)
  end

  test "inspection detects a lifecycle that bypassed append validation", context do
    assert {:ok, _} =
             Storage.append_thread_event(
               event("lifecycle-event", "lifecycle-item", "lifecycle-request", "prompt_queued"),
               context.store_opts
             )

    path = Path.join(context.root, "state/console.sqlite3")
    assert {:ok, conn} = Sqlite3.open(path)

    assert :ok =
             update(conn, "UPDATE thread_events SET event_type='prompt_started' WHERE event_id=?", ["lifecycle-event"])

    assert :ok = Sqlite3.close(conn)

    assert {:error, {:invalid_thread_event_lifecycle, "lifecycle-item", "prompt_started", :missing_queued}} =
             Storage.inspect_store(context.store_opts)
  end

  test "inspection rejects invalid canonical JSON and invalid event rows", context do
    assert {:ok, _} =
             Storage.append_thread_event(
               event("json-event", "json-item", "json-request", "prompt_queued"),
               context.store_opts
             )

    path = Path.join(context.root, "state/console.sqlite3")
    assert {:ok, conn} = Sqlite3.open(path)
    invalid = "{not-json"

    assert :ok =
             update(
               conn,
               "UPDATE thread_events SET payload_digest=?, encoded_bytes=?, payload_json=? WHERE event_id=?",
               [Digest.portable(invalid), byte_size(invalid), {:blob, invalid}, "json-event"]
             )

    assert :ok = Sqlite3.close(conn)
    assert {:error, {:thread_event_integrity_failed, "json-event", _reason}} = Storage.inspect_store(context.store_opts)
  end

  test "reads persisted payloads only when they match the event JSON object schema", context do
    assert {:ok, _} =
             Storage.append_thread_event(
               event("payload-shape-event", "payload-shape-item", "payload-shape-request", "prompt_queued"),
               context.store_opts
             )

    path = Path.join(context.root, "state/console.sqlite3")
    assert {:ok, conn} = Sqlite3.open(path)
    invalid = "[]"

    assert :ok =
             update(
               conn,
               "UPDATE thread_events SET payload_digest=?, encoded_bytes=?, payload_json=? WHERE event_id=?",
               [
                 Digest.portable(invalid),
                 byte_size(invalid),
                 {:blob, invalid},
                 "payload-shape-event"
               ]
             )

    assert :ok = Sqlite3.close(conn)

    assert {:error, {:thread_event_integrity_failed, "payload-shape-event", :invalid_thread_event}} =
             Storage.thread_events("thread-one", context.store_opts)
  end

  test "inspection rejects an event row with an incorrect byte count", context do
    assert {:ok, _} =
             Storage.append_thread_event(
               event("row-event", "row-item", "row-request", "prompt_queued"),
               context.store_opts
             )

    path = Path.join(context.root, "state/console.sqlite3")
    assert {:ok, conn} = Sqlite3.open(path)
    assert :ok = update(conn, "UPDATE thread_events SET encoded_bytes=encoded_bytes+1 WHERE event_id=?", ["row-event"])
    assert :ok = Sqlite3.close(conn)
    assert {:error, {:thread_event_integrity_failed, _row}} = Storage.inspect_store(context.store_opts)
  end

  test "detects duplicate event rows after live schema drift", context do
    path = Path.join(context.root, "state/console.sqlite3")
    assert {:ok, conn} = Sqlite3.open(path)
    assert :ok = Sqlite3.execute(conn, "DROP TABLE thread_events")

    assert :ok =
             Sqlite3.execute(
               conn,
               """
               CREATE TABLE thread_events(
                 thread_id TEXT,
                 sequence INTEGER,
                 event_id TEXT,
                 queue_item_id TEXT,
                 request_id TEXT,
                 event_type TEXT,
                 event_schema_version INTEGER,
                 jidoka_revision INTEGER,
                 payload_digest TEXT,
                 encoded_bytes INTEGER,
                 payload_json BLOB,
                 committed_at_ms INTEGER
               ) STRICT
               """
             )

    payload = "{}"

    for sequence <- 1..2 do
      assert :ok =
               update(conn, "INSERT INTO thread_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", [
                 "thread-one",
                 sequence,
                 "duplicate-event",
                 "item-#{sequence}",
                 "request-#{sequence}",
                 "prompt_queued",
                 1,
                 nil,
                 Digest.portable(payload),
                 byte_size(payload),
                 {:blob, payload},
                 0
               ])
    end

    assert :ok = Sqlite3.close(conn)

    assert {:error, {:thread_event_integrity_failed, "duplicate-event", :duplicate_rows}} =
             Storage.append_thread_event(
               event("duplicate-event", "new-item", "new-request", "prompt_queued"),
               context.store_opts
             )
  end

  test "inspection rejects an unexpected extra table", context do
    path = Path.join(context.root, "state/console.sqlite3")
    assert {:ok, conn} = Sqlite3.open(path)
    assert :ok = Sqlite3.execute(conn, "CREATE TABLE unexpected(value TEXT) STRICT")
    assert :ok = Sqlite3.close(conn)

    assert {:error, {:sqlite_integrity_failed, ["sessions", "thread_events", "unexpected"]}} =
             Storage.inspect_store(context.store_opts)
  end

  defp event(id, item_id, request_id, type, payload \\ %{}, jidoka_revision \\ nil) do
    {:ok, event} =
      Event.new(
        id: id,
        session_id: "thread-one",
        queue_item_id: item_id,
        request_id: request_id,
        type: type,
        payload: payload,
        jidoka_revision: jidoka_revision
      )

    event
  end

  defp session(id) do
    {:ok, session} = Data.start(spec(), session_id: id)
    session
  end

  defp spec do
    Agent.Spec.new!(
      id: "thread-event-agent",
      instructions: "Test product history.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp unique(label), do: String.to_atom("#{label}-#{System.unique_integer([:positive])}")

  defp update(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql),
         :ok <- Sqlite3.bind(statement, params),
         :done <- Sqlite3.step(conn, statement) do
      Sqlite3.release(conn, statement)
    end
  end
end
