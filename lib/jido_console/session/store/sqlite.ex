defmodule Jido.Console.Session.Store.SQLite do
  @moduledoc """
  Stores durable Console records and Jidoka sessions in one local SQLite file.

  The database is under `~/.jido/state/sessions/v1` by default. Console JSON records
  and opaque Jidoka values use separate tables. One process owns one writable
  connection. A successful mutation uses `synchronous=FULL` and replies only
  after its transaction commits.
  """

  use GenServer

  @behaviour Jidoka.Session.Store

  alias Exqlite.Sqlite3
  alias Jido.Console.Home
  alias Jido.Console.Session.Durable.{Catalog, JidokaValue, Record}
  alias Jidoka.Session.{Data, Transitions}
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  @store_format 1
  @default_limit 100
  @max_limit 1_000
  @default_bytes 8 * 1_024 * 1_024
  @database_bytes 1_024 * 1_024 * 1_024
  @normal_bytes 864 * 1_024 * 1_024
  @control_bytes 160 * 1_024 * 1_024
  @page_size 4_096
  @max_pages div(@database_bytes, @page_size)
  @normal_pages div(@normal_bytes, @page_size)
  @session_bytes 64 * 1_024 * 1_024
  @event_limit 10_000
  @session_limit 128
  @reader_limit 16
  @reserved_readers 4
  @reader_age_ms 1_000
  @exqlite_license "MIT"

  @schema """
  CREATE TABLE IF NOT EXISTS store_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS migrations (
    version INTEGER PRIMARY KEY,
    applied_at_ms INTEGER NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS session_heads (
    scope_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    sequence INTEGER NOT NULL,
    record_id TEXT NOT NULL,
    record_digest TEXT NOT NULL,
    PRIMARY KEY (scope_id, generation)
  ) STRICT;
  CREATE TABLE IF NOT EXISTS records (
    record_id TEXT PRIMARY KEY,
    scope_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    sequence INTEGER NOT NULL,
    record_type TEXT NOT NULL,
    prior_digest TEXT NOT NULL,
    digest TEXT NOT NULL UNIQUE,
    encoded_bytes INTEGER NOT NULL,
    json BLOB NOT NULL,
    UNIQUE (scope_id, generation, sequence)
  ) STRICT;
  CREATE INDEX IF NOT EXISTS records_scope_order
    ON records(scope_id, generation, sequence);
  CREATE TABLE IF NOT EXISTS snapshots (
    snapshot_id TEXT PRIMARY KEY,
    scope_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    sequence INTEGER NOT NULL,
    record_id TEXT NOT NULL UNIQUE,
    record_digest TEXT NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS jidoka_sessions (
    session_id TEXT PRIMARY KEY,
    revision INTEGER NOT NULL,
    schema_version INTEGER NOT NULL,
    value_digest TEXT NOT NULL,
    encoded_bytes INTEGER NOT NULL,
    value BLOB NOT NULL,
    updated_at_ms INTEGER NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS watermarks (
    scope_id TEXT PRIMARY KEY,
    console_generation INTEGER NOT NULL,
    console_sequence INTEGER NOT NULL,
    jidoka_revision INTEGER NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS operation_receipts (
    operation_id TEXT PRIMARY KEY,
    operation_kind TEXT NOT NULL,
    target_id TEXT NOT NULL,
    result_digest TEXT NOT NULL,
    committed_at_ms INTEGER NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS backups (
    backup_id TEXT PRIMARY KEY,
    state TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS archives (
    archive_id TEXT PRIMARY KEY,
    state TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS administrative_operations (
    operation_id TEXT PRIMARY KEY,
    operation_kind TEXT NOT NULL,
    state TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
  ) STRICT;
  """

  @type option :: {:path, Path.t()} | {:name, GenServer.name()} | {:jido_home, Path.t()}

  @doc "Starts the SQLite repository."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Returns the default versioned database path without creating it."
  @spec default_path(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def default_path(opts \\ []) do
    with {:ok, state} <- Home.path(:state, opts) do
      {:ok, Path.join([state, "sessions", "v1", "console.sqlite3"])}
    end
  end

  @doc "Returns the pinned adapter identity."
  @spec dependency_identity() :: map()
  def dependency_identity do
    %{name: :exqlite, version: to_string(Application.spec(:exqlite, :vsn)), license: @exqlite_license}
  end

  @doc "Returns fixed capacity and reader limits."
  @spec limits() :: map()
  def limits do
    %{
      database_bytes: @database_bytes,
      normal_bytes: @normal_bytes,
      control_reserve_bytes: @control_bytes,
      session_bytes: @session_bytes,
      canonical_events: @event_limit,
      active_sessions: @session_limit,
      jidoka_value_bytes: Catalog.limit("jidoka_value_bytes") |> elem(1),
      reader_limit: @reader_limit,
      reserved_readers: @reserved_readers,
      reader_age_ms: @reader_age_ms
    }
  end

  @doc "Appends one canonical Console record in an atomic transaction."
  @spec append(GenServer.server(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def append(server, record, opts \\ []) when is_map(record) and is_list(opts) do
    with {:ok, encoded} <- Record.encode(record),
         {:ok, operation_id} <- operation_id(opts) do
      call(server, {:append, operation_id, encoded}, opts)
    end
  end

  @doc "Reads an ordered, bounded record range."
  @spec range(GenServer.server(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def range(server, scope_id, opts \\ []) when is_binary(scope_id) and is_list(opts) do
    with {:ok, bounds} <- bounds(opts) do
      call(server, {:range, scope_id, bounds}, opts)
    end
  end

  @doc "Looks up the durable result of one mutation."
  @spec receipt(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def receipt(server, operation_id, opts \\ []) when is_binary(operation_id) do
    call(server, {:receipt, operation_id}, opts)
  end

  @doc "Checks SQLite, schema identity, pragmas, and row digests."
  @spec inspect_store(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_store(server, opts \\ []), do: call(server, :inspect, opts)

  @doc "Returns current page use and the fixed admission ceilings."
  @spec page_accounting(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def page_accounting(server, opts \\ []), do: call(server, :pages, opts)

  @impl true
  def init(opts) do
    with {:ok, path} <- store_path(opts),
         :ok <- prepare_path(path),
         {:ok, conn} <- Sqlite3.open(path),
         :ok <- configure(conn),
         :ok <- bootstrap(conn),
         :ok <- File.chmod(path, Home.file_mode()),
         :ok <- Home.check_private(path) do
      {:ok, %{conn: conn, path: path}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn}), do: Sqlite3.close(conn)

  @impl Jidoka.Session.Store
  def put_session(%Data{} = session, opts) do
    encoded_call(opts, :put, session.session_id, session, fn current -> Transitions.put(current, session) end)
  end

  @impl Jidoka.Session.Store
  def get_session(session_id, opts) when is_binary(session_id),
    do: call(fetch_server!(opts), {:get_session, session_id}, opts)

  @impl Jidoka.Session.Store
  def list_sessions(opts) do
    with {:ok, bounds} <- bounds(opts) do
      call(fetch_server!(opts), {:list_sessions, bounds}, opts)
    end
  end

  @impl Jidoka.Session.Store
  def claim_session(session_id, %Turn.Request{} = request, opts) when is_binary(session_id) do
    with :ok <- JidokaValue.validate(request) do
      transition_call(opts, :claim, session_id, &Transitions.claim(&1, request, opts))
    end
  end

  @impl Jidoka.Session.Store
  def claim_resume(session_id, opts) when is_binary(session_id),
    do: transition_call(opts, :resume, session_id, &Transitions.resume(&1, opts))

  @impl Jidoka.Session.Store
  def recover_session(session_id, opts) when is_binary(session_id),
    do: transition_call(opts, :recover, session_id, &Transitions.recover(&1, opts))

  @impl Jidoka.Session.Store
  def checkpoint_session(session_id, lease_id, %Snapshot{} = snapshot, opts)
      when is_binary(session_id) and is_binary(lease_id) do
    with :ok <- JidokaValue.validate(snapshot) do
      transition_call(opts, :checkpoint, session_id, &Transitions.checkpoint(&1, lease_id, snapshot, opts))
    end
  end

  @impl Jidoka.Session.Store
  def commit_session(session_id, lease_id, %Data{} = completed, opts)
      when is_binary(session_id) and is_binary(lease_id) do
    with :ok <- JidokaValue.validate(completed) do
      transition_call(opts, :commit, session_id, &Transitions.commit(&1, lease_id, completed, opts))
    end
  end

  @impl Jidoka.Session.Store
  def renew_session(session_id, lease_id, opts) when is_binary(session_id) and is_binary(lease_id),
    do: transition_call(opts, :renew, session_id, &Transitions.renew(&1, lease_id, opts))

  @impl true
  def handle_call({:append, operation_id, encoded}, _from, state) do
    result = transaction(state.conn, fn -> append_record(state.conn, operation_id, encoded) end)
    {:reply, result, state}
  end

  def handle_call({:range, scope_id, bounds}, _from, state) do
    {:reply, read_range(state.conn, scope_id, bounds), state}
  end

  def handle_call({:receipt, operation_id}, _from, state) do
    sql = "SELECT operation_kind,target_id,result_digest,committed_at_ms FROM operation_receipts WHERE operation_id=?"

    result =
      case query(state.conn, sql, [operation_id]) do
        {:ok, [[kind, target, digest, committed]]} ->
          {:ok,
           %{
             operation_id: operation_id,
             kind: kind,
             target_id: target,
             result_digest: digest,
             committed_at_ms: committed
           }}

        {:ok, []} ->
          {:error, {:operation_not_found, operation_id}}

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call({:get_session, session_id}, _from, state),
    do: {:reply, load_session(state.conn, session_id), state}

  def handle_call({:list_sessions, bounds}, _from, state),
    do: {:reply, list_stored_sessions(state.conn, bounds), state}

  def handle_call({:jidoka_transition, operation_id, kind, session_id, preencoded, transition}, _from, state) do
    result =
      transaction(state.conn, fn ->
        with {:ok, current} <- load_optional_session(state.conn, session_id),
             {:ok, %Data{} = updated} <- transition.(current),
             {:ok, encoded} <- use_or_encode(preencoded, updated),
             :ok <- admit_normal_write(state.conn, encoded.encoded_bytes),
             :ok <- persist_session(state.conn, encoded),
             :ok <- put_receipt(state.conn, operation_id, Atom.to_string(kind), session_id, encoded.digest) do
          {:ok, updated}
        end
      end)

    {:reply, result, state}
  end

  def handle_call(:pages, _from, state), do: {:reply, page_accounting_conn(state.conn), state}

  def handle_call(:inspect, _from, state) do
    result =
      with {:ok, [["ok"]]} <- query(state.conn, "PRAGMA integrity_check", []),
           :ok <- verify_pragmas(state.conn),
           :ok <- verify_record_digests(state.conn),
           :ok <- verify_jidoka_digests(state.conn),
           {:ok, pages} <- page_accounting_conn(state.conn) do
        {:ok, %{path: state.path, store_format: @store_format, integrity: :ok, pages: pages}}
      else
        {:ok, rows} -> {:error, {:sqlite_integrity_failed, rows}}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  defp encoded_call(opts, kind, session_id, %Data{} = session, transition) do
    with {:ok, encoded} <- JidokaValue.encode(session),
         {:ok, operation_id} <- jidoka_operation_id(opts, kind, session_id, session.revision) do
      call(fetch_server!(opts), {:jidoka_transition, operation_id, kind, session_id, encoded, transition}, opts)
    end
  end

  defp transition_call(opts, kind, session_id, transition) do
    revision = Keyword.get(opts, :expected_revision, "current")

    with {:ok, operation_id} <- jidoka_operation_id(opts, kind, session_id, revision) do
      call(fetch_server!(opts), {:jidoka_transition, operation_id, kind, session_id, nil, transition}, opts)
    end
  end

  defp append_record(conn, operation_id, encoded) do
    record = encoded.record
    scope_id = record["scope_id"]
    generation = record["generation"]
    sequence = record["sequence"]

    with :ok <- admit_normal_write(conn, encoded.encoded_bytes),
         :ok <- admit_record_scope(conn, scope_id, record["record_type"], encoded.encoded_bytes),
         :ok <- verify_head(conn, scope_id, generation, sequence, record["prior_record_digest"]),
         :ok <-
           execute(
             conn,
             "INSERT INTO records(record_id,scope_id,generation,sequence,record_type,prior_digest,digest,encoded_bytes,json) VALUES(?,?,?,?,?,?,?,?,?)",
             [
               record["record_id"],
               scope_id,
               generation,
               sequence,
               record["record_type"],
               record["prior_record_digest"],
               encoded.digest,
               encoded.encoded_bytes,
               {:blob, encoded.bytes}
             ]
           ),
         :ok <-
           execute(
             conn,
             "INSERT INTO session_heads(scope_id,generation,sequence,record_id,record_digest) VALUES(?,?,?,?,?) ON CONFLICT(scope_id,generation) DO UPDATE SET sequence=excluded.sequence,record_id=excluded.record_id,record_digest=excluded.record_digest",
             [scope_id, generation, sequence, record["record_id"], encoded.digest]
           ),
         :ok <- maybe_snapshot(conn, record, encoded.digest),
         :ok <- put_receipt(conn, operation_id, "append", record["record_id"], encoded.digest) do
      {:ok, %{record_id: record["record_id"], digest: encoded.digest, sequence: sequence}}
    end
  end

  defp verify_head(conn, scope_id, generation, 0, "genesis") do
    case query(conn, "SELECT 1 FROM session_heads WHERE scope_id=? AND generation=?", [scope_id, generation]) do
      {:ok, []} -> :ok
      {:ok, _rows} -> {:error, {:record_sequence_conflict, scope_id, generation, 0}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_head(conn, scope_id, generation, sequence, prior_digest) when sequence > 0 do
    case query(conn, "SELECT sequence,record_digest FROM session_heads WHERE scope_id=? AND generation=?", [
           scope_id,
           generation
         ]) do
      {:ok, [[prior_sequence, ^prior_digest]]} when prior_sequence + 1 == sequence -> :ok
      {:ok, rows} -> {:error, {:record_head_conflict, scope_id, generation, sequence, rows}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_head(_conn, scope_id, generation, sequence, _prior),
    do: {:error, {:record_sequence_conflict, scope_id, generation, sequence}}

  defp maybe_snapshot(conn, %{"record_type" => "snapshot"} = record, digest) do
    snapshot_id = get_in(record, ["payload", "snapshot_id"])

    execute(
      conn,
      "INSERT INTO snapshots(snapshot_id,scope_id,generation,sequence,record_id,record_digest) VALUES(?,?,?,?,?,?)",
      [snapshot_id, record["scope_id"], record["generation"], record["sequence"], record["record_id"], digest]
    )
  end

  defp maybe_snapshot(_conn, _record, _digest), do: :ok

  defp read_range(conn, scope_id, %{after: after_sequence, limit: limit, bytes: max_bytes}) do
    sql =
      "SELECT json,digest,encoded_bytes FROM records WHERE scope_id=? AND sequence>? ORDER BY generation,sequence LIMIT ?"

    with {:ok, rows} <- query(conn, sql, [scope_id, after_sequence, limit]) do
      bounded_decode(rows, max_bytes, [])
    end
  end

  defp bounded_decode([[bytes, digest, size] | rows], remaining, acc) when size <= remaining do
    case Record.decode(bytes) do
      {:ok, encoded} when encoded.digest == digest -> bounded_decode(rows, remaining - size, [encoded | acc])
      {:ok, _encoded} -> {:error, :record_digest_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounded_decode([_row | _rows], _remaining, acc), do: {:ok, Enum.reverse(acc)}
  defp bounded_decode([], _remaining, acc), do: {:ok, Enum.reverse(acc)}

  defp persist_session(conn, encoded) do
    session = encoded.value

    with :ok <- admit_session(conn, session.session_id) do
      execute(
        conn,
        "INSERT INTO jidoka_sessions(session_id,revision,schema_version,value_digest,encoded_bytes,value,updated_at_ms) VALUES(?,?,?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET revision=excluded.revision,schema_version=excluded.schema_version,value_digest=excluded.value_digest,encoded_bytes=excluded.encoded_bytes,value=excluded.value,updated_at_ms=excluded.updated_at_ms",
        [
          session.session_id,
          session.revision,
          session.schema_version,
          encoded.digest,
          encoded.encoded_bytes,
          {:blob, encoded.bytes},
          now_ms()
        ]
      )
    end
  end

  defp load_optional_session(conn, session_id) do
    case load_session(conn, session_id) do
      {:ok, session} -> {:ok, session}
      {:error, {:session_not_found, ^session_id}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_session(conn, session_id) do
    case query(conn, "SELECT value,value_digest FROM jidoka_sessions WHERE session_id=?", [session_id]) do
      {:ok, [[bytes, digest]]} -> decode_jidoka(bytes, digest)
      {:ok, []} -> {:error, {:session_not_found, session_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_stored_sessions(conn, %{limit: limit, bytes: max_bytes}) do
    with {:ok, rows} <-
           query(conn, "SELECT value,value_digest,encoded_bytes FROM jidoka_sessions ORDER BY session_id LIMIT ?", [
             limit
           ]) do
      bounded_jidoka(rows, max_bytes, [])
    end
  end

  defp bounded_jidoka([[bytes, digest, size] | rows], remaining, acc) when size <= remaining do
    case decode_jidoka(bytes, digest) do
      {:ok, session} -> bounded_jidoka(rows, remaining - size, [session | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounded_jidoka([_row | _rows], _remaining, acc), do: {:ok, Enum.reverse(acc)}
  defp bounded_jidoka([], _remaining, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_jidoka(bytes, digest) do
    case JidokaValue.decode(bytes) do
      {:ok, encoded} when encoded.digest == digest -> {:ok, encoded.value}
      {:ok, _encoded} -> {:error, :jidoka_value_digest_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp use_or_encode(%{value: value} = encoded, value), do: {:ok, encoded}
  defp use_or_encode(_preencoded, %Data{} = updated), do: JidokaValue.encode(updated)

  defp put_receipt(conn, operation_id, kind, target_id, digest) do
    execute(
      conn,
      "INSERT INTO operation_receipts(operation_id,operation_kind,target_id,result_digest,committed_at_ms) VALUES(?,?,?,?,?)",
      [operation_id, kind, target_id, digest, now_ms()]
    )
  end

  defp configure(conn) do
    with :ok <- Sqlite3.set_busy_timeout(conn, 5_000),
         :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=WAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA synchronous=FULL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA foreign_keys=ON"),
         :ok <- Sqlite3.execute(conn, "PRAGMA trusted_schema=OFF"),
         :ok <- Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY"),
         :ok <- Sqlite3.execute(conn, "PRAGMA page_size=#{@page_size}"),
         :ok <- Sqlite3.execute(conn, "PRAGMA max_page_count=#{@max_pages}"),
         :ok <- Sqlite3.execute(conn, "PRAGMA cache_size=-32768") do
      verify_pragmas(conn)
    end
  end

  defp verify_pragmas(conn) do
    checks = [
      {"journal_mode", "wal"},
      {"synchronous", 2},
      {"foreign_keys", 1},
      {"trusted_schema", 0},
      {"temp_store", 2},
      {"page_size", @page_size},
      {"max_page_count", @max_pages}
    ]

    Enum.reduce_while(checks, :ok, fn {name, expected}, :ok ->
      case query(conn, "PRAGMA #{name}", []) do
        {:ok, [[^expected]]} -> {:cont, :ok}
        {:ok, rows} -> {:halt, {:error, {:sqlite_pragma_mismatch, name, expected, rows}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp bootstrap(conn) do
    transaction(conn, fn ->
      with :ok <- Sqlite3.execute(conn, @schema),
           :ok <- ensure_metadata(conn, "store_format", Integer.to_string(@store_format)),
           :ok <- ensure_metadata(conn, "exqlite_version", dependency_identity().version),
           :ok <- ensure_metadata(conn, "exqlite_license", @exqlite_license) do
        execute(conn, "INSERT OR IGNORE INTO migrations(version,applied_at_ms) VALUES(?,?)", [0, now_ms()])
      end
    end)
  end

  defp ensure_metadata(conn, key, value) do
    with :ok <- execute(conn, "INSERT OR IGNORE INTO store_metadata(key,value) VALUES(?,?)", [key, value]) do
      case query(conn, "SELECT value FROM store_metadata WHERE key=?", [key]) do
        {:ok, [[^value]]} -> :ok
        {:ok, rows} -> {:error, {:incompatible_store_metadata, key, value, rows}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp transaction(conn, fun) do
    with :ok <- Sqlite3.execute(conn, "BEGIN IMMEDIATE") do
      case fun.() do
        :ok -> commit(conn, :ok)
        {:ok, _value} = ok -> commit(conn, ok)
        {:error, _reason} = error -> rollback(conn, error)
      end
    end
  rescue
    error ->
      _result = Sqlite3.execute(conn, "ROLLBACK")
      {:error, {:sqlite_transaction_failed, Exception.message(error)}}
  end

  defp commit(conn, result) do
    case Sqlite3.execute(conn, "COMMIT") do
      :ok -> result
      {:error, reason} -> {:error, {:sqlite_commit_failed, reason}}
    end
  end

  defp rollback(conn, result) do
    _result = Sqlite3.execute(conn, "ROLLBACK")
    result
  end

  defp execute(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, params),
             :done <- Sqlite3.step(conn, statement) do
          :ok
        else
          {:error, reason} -> {:error, normalize_sqlite_error(reason)}
          other -> {:error, {:unexpected_sqlite_result, other}}
        end
      after
        _result = Sqlite3.release(conn, statement)
      end
    end
  end

  defp query(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, params) do
          Sqlite3.fetch_all(conn, statement)
        end
      after
        _result = Sqlite3.release(conn, statement)
      end
    end
  end

  defp normalize_sqlite_error(reason) when is_binary(reason) do
    if String.contains?(reason, "UNIQUE constraint failed"),
      do: {:constraint_conflict, reason},
      else: {:sqlite_error, reason}
  end

  defp normalize_sqlite_error(reason), do: {:sqlite_error, reason}

  defp page_accounting_conn(conn) do
    with {:ok, [[page_count]]} <- query(conn, "PRAGMA page_count", []),
         {:ok, [[page_size]]} <- query(conn, "PRAGMA page_size", []) do
      used = page_count * page_size

      {:ok,
       %{
         page_count: page_count,
         page_size: page_size,
         used_bytes: used,
         normal_page_ceiling: @normal_pages,
         normal_bytes_remaining: max(@normal_bytes - used, 0),
         control_reserve_bytes: @control_bytes,
         database_bytes: @database_bytes
       }}
    end
  end

  defp admit_normal_write(conn, bytes) do
    with {:ok, %{used_bytes: used}} <- page_accounting_conn(conn) do
      if used + bytes <= @normal_bytes, do: :ok, else: {:error, {:store_capacity_exceeded, used, bytes, @normal_bytes}}
    end
  end

  defp admit_record_scope(conn, scope_id, record_type, bytes) do
    with {:ok, [[stored_bytes]]} <-
           query(conn, "SELECT COALESCE(SUM(encoded_bytes),0) FROM records WHERE scope_id=?", [scope_id]),
         true <- stored_bytes + bytes <= @session_bytes,
         {:ok, [[events]]} <-
           query(conn, "SELECT COUNT(*) FROM records WHERE scope_id=? AND record_type='canonical_console_event'", [
             scope_id
           ]),
         true <- record_type != "canonical_console_event" or events < @event_limit do
      :ok
    else
      false -> {:error, {:session_store_limit_exceeded, scope_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp admit_session(conn, session_id) do
    with {:ok, [[present]]} <- query(conn, "SELECT COUNT(*) FROM jidoka_sessions WHERE session_id=?", [session_id]),
         {:ok, [[count]]} <- query(conn, "SELECT COUNT(*) FROM jidoka_sessions", []) do
      if present == 1 or count < @session_limit,
        do: :ok,
        else: {:error, {:active_session_limit_exceeded, @session_limit}}
    end
  end

  defp verify_record_digests(conn) do
    with {:ok, rows} <-
           query(conn, "SELECT record_id,json,digest FROM records ORDER BY scope_id,generation,sequence", []) do
      Enum.reduce_while(rows, :ok, fn [id, bytes, digest], :ok ->
        case Record.decode(bytes) do
          {:ok, %{digest: ^digest}} -> {:cont, :ok}
          _other -> {:halt, {:error, {:record_integrity_failed, id}}}
        end
      end)
    end
  end

  defp verify_jidoka_digests(conn) do
    with {:ok, rows} <- query(conn, "SELECT session_id,value,value_digest FROM jidoka_sessions ORDER BY session_id", []) do
      Enum.reduce_while(rows, :ok, fn [id, bytes, digest], :ok ->
        case decode_jidoka(bytes, digest) do
          {:ok, _session} -> {:cont, :ok}
          _other -> {:halt, {:error, {:jidoka_integrity_failed, id}}}
        end
      end)
    end
  end

  defp store_path(opts) do
    case Keyword.get(opts, :path) do
      nil ->
        home_opts = Keyword.take(opts, [:jido_home, :user_home])

        with {:ok, _home} <- Home.ensure(home_opts),
             {:ok, state} <- Home.path(:state, home_opts),
             :ok <- ensure_private_subdirectory(Path.join(state, "sessions")),
             :ok <- ensure_private_subdirectory(Path.join([state, "sessions", "v1"])) do
          {:ok, Path.join([state, "sessions", "v1", "console.sqlite3"])}
        end

      path when is_binary(path) and path != "" ->
        {:ok, Path.expand(path)}

      path ->
        {:error, {:invalid_sqlite_store_path, path}}
    end
  end

  defp ensure_private_subdirectory(path) do
    with :ok <- File.mkdir(path) |> accept_existing_directory(),
         :ok <- File.chmod(path, Home.directory_mode()) do
      Home.check_private(path)
    end
  end

  defp accept_existing_directory(:ok), do: :ok

  defp accept_existing_directory({:error, :eexist}), do: :ok

  defp accept_existing_directory({:error, reason}), do: {:error, {:store_directory_unavailable, reason}}

  defp prepare_path(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), Home.directory_mode()) do
      case File.lstat(path) do
        {:ok, _stat} -> Home.check_private(path)
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:store_path_unavailable, path, reason}}
      end
    end
  end

  defp operation_id(opts) do
    case Keyword.fetch(opts, :operation_id) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :operation_id_required}
    end
  end

  defp jidoka_operation_id(opts, kind, session_id, revision) do
    case Keyword.get(opts, :operation_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:ok, "jidoka:#{kind}:#{session_id}:#{revision}"}
    end
  end

  defp bounds(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    bytes = Keyword.get(opts, :max_bytes, @default_bytes)
    after_sequence = Keyword.get(opts, :after, -1)

    if is_integer(limit) and limit > 0 and limit <= @max_limit and is_integer(bytes) and bytes > 0 and
         is_integer(after_sequence) and after_sequence >= -1 do
      {:ok, %{limit: limit, bytes: bytes, after: after_sequence}}
    else
      {:error, :invalid_query_bounds}
    end
  end

  defp fetch_server!(opts) do
    case Keyword.fetch(opts, :pid) do
      {:ok, server} -> server
      :error -> raise ArgumentError, "SQLite session store requires :pid"
    end
  end

  defp call(server, message, opts), do: GenServer.call(server, message, Keyword.get(opts, :call_timeout, 30_000))
  defp now_ms, do: System.system_time(:millisecond)
end
