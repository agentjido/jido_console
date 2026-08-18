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
  alias Jido.Console.Digest
  alias Jido.Console.Home
  alias Jido.Console.Session.Durable.{CanonicalJSON, Catalog, JidokaValue, Record, SemanticSnapshot}
  alias Jido.Console.Session.Event
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
  @credential_profile_limit 128
  @credential_profile_version_limit 128
  @credential_profile_list_bytes 2 * 1_024 * 1_024
  @reader_limit 16
  @reserved_readers 4
  @reader_age_ms 1_000
  @wal_soft_bytes 64 * 1_024 * 1_024
  @wal_hard_bytes 384 * 1_024 * 1_024
  @wal_autocheckpoint_pages div(@wal_soft_bytes, @page_size)
  @exqlite_license "MIT"
  @admission_schema "1"
  @max_generation 9_223_372_036_854_775_807

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
  CREATE TABLE IF NOT EXISTS history_heads (
    scope_id TEXT PRIMARY KEY,
    generation INTEGER NOT NULL,
    sequence INTEGER NOT NULL,
    record_id TEXT NOT NULL,
    chain_digest TEXT NOT NULL,
    suffix_events INTEGER NOT NULL,
    suffix_bytes INTEGER NOT NULL
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
  CREATE TABLE IF NOT EXISTS canonical_event_index (
    event_id TEXT PRIMARY KEY,
    scope_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    record_id TEXT NOT NULL UNIQUE,
    event_digest TEXT NOT NULL,
    UNIQUE (scope_id, sequence)
  ) STRICT;
  CREATE INDEX IF NOT EXISTS canonical_event_scope_order
    ON canonical_event_index(scope_id, sequence);
  CREATE TRIGGER IF NOT EXISTS canonical_event_index_no_update
    BEFORE UPDATE ON canonical_event_index BEGIN SELECT RAISE(ABORT, 'canonical event index is immutable'); END;
  CREATE TRIGGER IF NOT EXISTS canonical_event_index_no_delete
    BEFORE DELETE ON canonical_event_index BEGIN SELECT RAISE(ABORT, 'canonical event index is immutable'); END;
  CREATE TRIGGER IF NOT EXISTS canonical_event_record_no_update
    BEFORE UPDATE ON records WHEN OLD.record_type='canonical_console_event'
    BEGIN SELECT RAISE(ABORT, 'canonical event record is immutable'); END;
  CREATE TRIGGER IF NOT EXISTS canonical_event_record_no_delete
    BEFORE DELETE ON records WHEN OLD.record_type='canonical_console_event'
    BEGIN SELECT RAISE(ABORT, 'canonical event record is immutable'); END;
  CREATE TABLE IF NOT EXISTS semantic_snapshots (
    snapshot_id TEXT PRIMARY KEY,
    scope_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    source_sequence INTEGER NOT NULL,
    source_chain_digest TEXT NOT NULL,
    snapshot_digest TEXT NOT NULL,
    encoded_bytes INTEGER NOT NULL,
    snapshot BLOB NOT NULL,
    reason TEXT NOT NULL,
    referenced INTEGER NOT NULL DEFAULT 0 CHECK (referenced IN (0, 1)),
    created_at_ms INTEGER NOT NULL
  ) STRICT;
  CREATE INDEX IF NOT EXISTS semantic_snapshots_scope_order
    ON semantic_snapshots(scope_id, source_sequence DESC, created_at_ms DESC);
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
  CREATE TABLE IF NOT EXISTS session_generations (
    session_id TEXT PRIMARY KEY,
    generation INTEGER NOT NULL CHECK (generation > 0),
    owner_instance_id TEXT NOT NULL,
    claim_operation_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('active', 'released')),
    jidoka_lease_id TEXT,
    claimed_at_ms INTEGER NOT NULL,
    released_at_ms INTEGER
  ) STRICT;
  CREATE TABLE IF NOT EXISTS generation_audit (
    operation_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    owner_instance_id TEXT NOT NULL,
    transition TEXT NOT NULL CHECK (transition IN ('claimed', 'released')),
    jidoka_lease_id TEXT,
    occurred_at_ms INTEGER NOT NULL
  ) STRICT;
  CREATE INDEX IF NOT EXISTS generation_audit_session_order
    ON generation_audit(session_id, generation, occurred_at_ms);
  CREATE TRIGGER IF NOT EXISTS generation_audit_no_update
    BEFORE UPDATE ON generation_audit BEGIN SELECT RAISE(ABORT, 'generation audit is immutable'); END;
  CREATE TRIGGER IF NOT EXISTS generation_audit_no_delete
    BEFORE DELETE ON generation_audit BEGIN SELECT RAISE(ABORT, 'generation audit is immutable'); END;
  CREATE TABLE IF NOT EXISTS operation_receipts (
    operation_id TEXT PRIMARY KEY,
    operation_kind TEXT NOT NULL,
    target_id TEXT NOT NULL,
    result_digest TEXT NOT NULL,
    committed_at_ms INTEGER NOT NULL
  ) STRICT;
  CREATE TABLE IF NOT EXISTS admission_receipts (
    receipt_id TEXT PRIMARY KEY,
    operation_id TEXT NOT NULL UNIQUE,
    scope_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    sequence INTEGER NOT NULL,
    operation_kind TEXT NOT NULL,
    principal_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    payload_digest TEXT NOT NULL,
    target_id TEXT NOT NULL,
    event_id TEXT NOT NULL UNIQUE,
    admission_state TEXT NOT NULL CHECK (admission_state IN ('accepted', 'started', 'terminal')),
    record_digest TEXT NOT NULL,
    encoded_bytes INTEGER NOT NULL,
    record BLOB NOT NULL,
    committed_at_ms INTEGER NOT NULL,
    UNIQUE (scope_id, operation_kind, principal_id, idempotency_key)
  ) STRICT;
  CREATE INDEX IF NOT EXISTS admission_receipts_recovery
    ON admission_receipts(scope_id, admission_state, sequence);
  CREATE TRIGGER IF NOT EXISTS admission_receipts_no_update
    BEFORE UPDATE ON admission_receipts BEGIN SELECT RAISE(ABORT, 'admission receipt is immutable'); END;
  CREATE TRIGGER IF NOT EXISTS admission_receipts_no_delete
    BEFORE DELETE ON admission_receipts BEGIN SELECT RAISE(ABORT, 'admission receipt is immutable'); END;
  CREATE TABLE IF NOT EXISTS admission_transitions (
    operation_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    transition_operation_id TEXT NOT NULL UNIQUE,
    admission_state TEXT NOT NULL CHECK (admission_state IN ('accepted', 'started', 'terminal')),
    committed_at_ms INTEGER NOT NULL,
    PRIMARY KEY (operation_id, ordinal),
    FOREIGN KEY (operation_id) REFERENCES admission_receipts(operation_id)
  ) STRICT;
  CREATE INDEX IF NOT EXISTS admission_transitions_latest
    ON admission_transitions(operation_id, ordinal DESC);
  CREATE TRIGGER IF NOT EXISTS admission_transitions_no_update
    BEFORE UPDATE ON admission_transitions BEGIN SELECT RAISE(ABORT, 'admission transition is immutable'); END;
  CREATE TRIGGER IF NOT EXISTS admission_transitions_no_delete
    BEFORE DELETE ON admission_transitions BEGIN SELECT RAISE(ABORT, 'admission transition is immutable'); END;
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
      call(server, {:append, operation_id, Keyword.get(opts, :fence), encoded}, opts)
    end
  end

  @doc "Appends one canonical Console event and advances its session chain atomically."
  @spec append_event(GenServer.server(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def append_event(server, event, position, opts \\ [])
      when is_map(event) and is_map(position) and is_list(opts) do
    with {:ok, event} <- Event.validate(event),
         :ok <- validate_event_state(event["session_id"], get_in(event, ["payload", "sequence"]), position),
         {:ok, operation_id} <- operation_id(opts) do
      call(server, {:append_event, operation_id, Keyword.get(opts, :fence), event, position}, opts)
    end
  end

  @doc "Atomically commits one durable admission receipt and canonical event."
  @spec admit_operation(GenServer.server(), map(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def admit_operation(server, prepared, event, position, opts \\ [])
      when is_map(prepared) and is_map(event) and is_map(position) and is_list(opts) do
    with {:ok, event} <- Event.validate(event),
         :ok <- validate_event_state(event["session_id"], get_in(event, ["payload", "sequence"]), position),
         {:ok, operation_id} <- operation_id(opts),
         true <- operation_id == prepared.operation_id do
      call(
        server,
        {:admit_operation, operation_id, Keyword.get(opts, :fence), prepared, event, position},
        opts
      )
    else
      false -> {:error, :admission_operation_identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns one exact durable admission receipt."
  @spec admission_receipt(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def admission_receipt(server, operation_id, opts \\ []) when is_binary(operation_id) do
    call(server, {:admission_receipt, operation_id}, opts)
  end

  @doc "Appends one idempotent admission lifecycle transition."
  @spec transition_admission(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def transition_admission(server, operation_id, state, opts \\ [])

  def transition_admission(server, operation_id, state, opts)
      when is_binary(operation_id) and state in ["started", "terminal"] do
    with {:ok, transition_operation_id} <- operation_id(opts) do
      call(
        server,
        {:transition_admission, transition_operation_id, Keyword.get(opts, :fence), operation_id, state},
        opts
      )
    end
  end

  def transition_admission(_server, _operation_id, _state, _opts),
    do: {:error, :invalid_admission_transition}

  @doc "Returns bounded durable admissions for restart recovery."
  @spec recover_admissions(GenServer.server(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def recover_admissions(server, session_id, opts \\ []) when is_binary(session_id) do
    limit = Keyword.get(opts, :limit, 100)
    states = Keyword.get(opts, :states, ["accepted", "started", "terminal"])

    if is_integer(limit) and limit > 0 and limit <= 1_000 and is_list(states) and states != [] and
         Enum.all?(states, &(&1 in ["accepted", "started", "terminal"])) do
      call(server, {:recover_admissions, session_id, states, limit}, opts)
    else
      {:error, :invalid_admission_recovery_bounds}
    end
  end

  @doc "Returns the durable canonical event head for one session."
  @spec history_head(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def history_head(server, session_id, opts \\ []) when is_binary(session_id) do
    call(server, {:history_head, session_id}, opts)
  end

  @doc "Stores one verified derived semantic snapshot and resets suffix counters."
  @spec put_semantic_snapshot(GenServer.server(), SemanticSnapshot.encoded(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def put_semantic_snapshot(server, encoded, opts \\ []) when is_map(encoded) and is_list(opts) do
    with {:ok, operation_id} <- operation_id(opts) do
      call(server, {:put_semantic_snapshot, operation_id, Keyword.get(opts, :fence), encoded}, opts)
    end
  end

  @doc "Returns at most the latest three retained semantic snapshot candidates."
  @spec semantic_snapshots(GenServer.server(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def semantic_snapshots(server, session_id, opts \\ []) when is_binary(session_id) do
    call(server, {:semantic_snapshots, session_id}, opts)
  end

  @doc "Returns one verified and bounded canonical event suffix."
  @spec history_suffix(GenServer.server(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def history_suffix(server, session_id, opts \\ []) when is_binary(session_id) do
    with {:ok, bounds} <- history_bounds(opts) do
      call(server, {:history_suffix, session_id, bounds}, opts)
    end
  end

  @doc "Reads an ordered, bounded record range."
  @spec range(GenServer.server(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def range(server, scope_id, opts \\ []) when is_binary(scope_id) and is_list(opts) do
    with {:ok, bounds} <- bounds(opts) do
      call(server, {:range, scope_id, bounds}, opts)
    end
  end

  @doc "Lists the latest immutable credential-profile record for each profile."
  @spec credential_profile_records(GenServer.server(), keyword()) ::
          {:ok, [Record.encoded()]} | {:error, term()}
  def credential_profile_records(server, opts \\ []) when is_list(opts) do
    with {:ok, bounds} <- profile_bounds(opts) do
      call(server, {:credential_profile_records, bounds}, opts)
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

  @doc "Runs the bounded WAL checkpoint state machine and returns measured WAL bytes."
  @spec checkpoint(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def checkpoint(server, opts \\ []), do: call(server, :checkpoint, opts)

  @doc "Returns the current durable generation for one session."
  @spec generation(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generation(server, session_id, opts \\ []) when is_binary(session_id) do
    call(server, {:generation, session_id}, opts)
  end

  @doc "Claims exactly the generation after the caller's expected generation."
  @spec claim_generation(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_generation(server, session_id, opts \\ []) when is_binary(session_id) do
    with {:ok, expected} <- expected_generation(opts),
         {:ok, owner_instance_id} <- owner_instance_id(opts),
         {:ok, operation_id} <- operation_id(opts),
         {:ok, jidoka_lease_id} <- optional_token(opts, :jidoka_lease_id) do
      call(
        server,
        {:claim_generation, session_id, expected, owner_instance_id, operation_id, jidoka_lease_id},
        opts
      )
    end
  end

  @doc "Releases an exact active durable generation without reusing it."
  @spec release_generation(GenServer.server(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def release_generation(server, fence, opts \\ []) when is_map(fence) do
    with {:ok, operation_id} <- operation_id(opts) do
      call(server, {:release_generation, fence, operation_id}, opts)
    end
  end

  @doc "Returns the immutable generation transition history for one session."
  @spec generation_audit(GenServer.server(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def generation_audit(server, session_id, opts \\ []) when is_binary(session_id) do
    call(server, {:generation_audit, session_id}, opts)
  end

  @impl true
  def init(opts) do
    with {:ok, path} <- store_path(opts),
         :ok <- prepare_path(path),
         {:ok, conn} <- Sqlite3.open(path),
         :ok <- configure(conn),
         :ok <- bootstrap(conn),
         :ok <- File.chmod(path, Home.file_mode()),
         :ok <- protect_owned_files(path),
         :ok <- maybe_integrity_gate(conn, opts) do
      {:ok, %{conn: conn, path: path, admission: Keyword.get(opts, :admission)}}
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
  def handle_call({:append, operation_id, fence, encoded}, _from, state) do
    result =
      with {:ok, value} <-
             transaction(state.conn, fn ->
               with :ok <- verify_generation_fence(state.conn, encoded.record["scope_id"], fence, operation_id) do
                 append_record(state.conn, operation_id, encoded)
               end
             end),
           :ok <- protect_owned_files(state.path) do
        {:ok, value}
      end

    {:reply, result, state}
  end

  def handle_call({:append_event, operation_id, fence, event, semantic}, _from, state) do
    session_id = event["session_id"]

    result =
      with {:ok, value} <-
             transaction(state.conn, fn ->
               with :ok <- verify_generation_fence(state.conn, session_id, fence, operation_id) do
                 append_event_conn(state.conn, operation_id, event, semantic)
               end
             end),
           :ok <- protect_owned_files(state.path) do
        {:ok, value}
      end

    {:reply, result, state}
  end

  def handle_call(
        {:admit_operation, operation_id, fence, prepared, event, semantic},
        _from,
        state
      ) do
    session_id = event["session_id"]

    result =
      with {:ok, value} <-
             transaction(state.conn, fn ->
               with :ok <- verify_generation_fence(state.conn, session_id, fence, operation_id) do
                 admit_operation_conn(state.conn, prepared, event, semantic)
               end
             end),
           :ok <- protect_owned_files(state.path) do
        {:ok, value}
      end

    {:reply, result, state}
  end

  def handle_call({:admission_receipt, operation_id}, _from, state) do
    {:reply, load_admission_receipt(state.conn, operation_id), state}
  end

  def handle_call(
        {:transition_admission, transition_operation_id, fence, operation_id, next_state},
        _from,
        state
      ) do
    result =
      with {:ok, value} <-
             transaction(state.conn, fn ->
               with {:ok, receipt} <- load_admission_receipt(state.conn, operation_id),
                    :ok <-
                      verify_generation_fence(
                        state.conn,
                        receipt.session_id,
                        fence,
                        transition_operation_id
                      ) do
                 transition_admission_conn(
                   state.conn,
                   receipt,
                   transition_operation_id,
                   next_state
                 )
               end
             end),
           :ok <- protect_owned_files(state.path) do
        {:ok, value}
      end

    {:reply, result, state}
  end

  def handle_call({:recover_admissions, session_id, states, limit}, _from, state) do
    {:reply, read_recoverable_admissions(state.conn, session_id, states, limit), state}
  end

  def handle_call({:history_head, session_id}, _from, state) do
    {:reply, load_history_head(state.conn, session_id), state}
  end

  def handle_call({:put_semantic_snapshot, operation_id, fence, encoded}, _from, state) do
    session_id = get_in(encoded, [:value, "session_id"])

    result =
      with {:ok, value} <-
             transaction(state.conn, fn ->
               with :ok <- verify_generation_fence(state.conn, session_id, fence, operation_id) do
                 put_semantic_snapshot_conn(state.conn, operation_id, encoded)
               end
             end),
           :ok <- protect_owned_files(state.path) do
        {:ok, value}
      end

    {:reply, result, state}
  end

  def handle_call({:semantic_snapshots, session_id}, _from, state) do
    {:reply, read_semantic_snapshots(state.conn, session_id), state}
  end

  def handle_call({:history_suffix, session_id, bounds}, _from, state) do
    {:reply, read_history_suffix(state.conn, session_id, bounds), state}
  end

  def handle_call({:range, scope_id, bounds}, _from, state) do
    {:reply, read_range(state.conn, scope_id, bounds), state}
  end

  def handle_call({:credential_profile_records, bounds}, _from, state) do
    {:reply, read_credential_profile_records(state.conn, bounds), state}
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

  def handle_call({:generation, session_id}, _from, state),
    do: {:reply, load_generation(state.conn, session_id), state}

  def handle_call(
        {:claim_generation, session_id, expected, owner_instance_id, operation_id, jidoka_lease_id},
        _from,
        state
      ) do
    result =
      transaction(state.conn, fn ->
        claim_generation_conn(
          state.conn,
          session_id,
          expected,
          owner_instance_id,
          operation_id,
          jidoka_lease_id
        )
      end)

    result = with {:ok, value} <- result, :ok <- protect_owned_files(state.path), do: {:ok, value}
    {:reply, result, state}
  end

  def handle_call({:release_generation, fence, operation_id}, _from, state) do
    result = transaction(state.conn, fn -> release_generation_conn(state.conn, fence, operation_id) end)
    result = with {:ok, value} <- result, :ok <- protect_owned_files(state.path), do: {:ok, value}
    {:reply, result, state}
  end

  def handle_call({:generation_audit, session_id}, _from, state),
    do: {:reply, read_generation_audit(state.conn, session_id), state}

  def handle_call(
        {:jidoka_transition, operation_id, kind, session_id, fence, preencoded, transition},
        _from,
        state
      ) do
    result =
      transaction(state.conn, fn ->
        with :ok <- verify_generation_fence(state.conn, session_id, fence, operation_id),
             {:ok, current} <- load_optional_session(state.conn, session_id),
             {:ok, %Data{} = updated} <- transition.(current),
             {:ok, encoded} <- use_or_encode(preencoded, updated),
             :ok <- admit_normal_write(state.conn, encoded.encoded_bytes),
             :ok <- persist_session(state.conn, encoded),
             :ok <- put_receipt(state.conn, operation_id, Atom.to_string(kind), session_id, encoded.digest) do
          {:ok, updated}
        end
      end)

    result = with {:ok, value} <- result, :ok <- protect_owned_files(state.path), do: {:ok, value}
    {:reply, result, state}
  end

  def handle_call(:pages, _from, state), do: {:reply, page_accounting_conn(state.conn), state}

  def handle_call(:checkpoint, _from, state) do
    {:reply, checkpoint_wal(state.conn, state.path), state}
  end

  def handle_call(:inspect, _from, state) do
    result =
      with {:ok, [["ok"]]} <- query(state.conn, "PRAGMA integrity_check", []),
           :ok <- verify_pragmas(state.conn),
           :ok <- verify_record_digests(state.conn),
           :ok <- verify_admission_receipts(state.conn),
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
      call(
        fetch_server!(opts),
        {:jidoka_transition, operation_id, kind, session_id, Keyword.get(opts, :console_fence), encoded, transition},
        opts
      )
    end
  end

  defp transition_call(opts, kind, session_id, transition) do
    revision = Keyword.get(opts, :expected_revision, "current")

    with {:ok, operation_id} <- jidoka_operation_id(opts, kind, session_id, revision) do
      call(
        fetch_server!(opts),
        {:jidoka_transition, operation_id, kind, session_id, Keyword.get(opts, :console_fence), nil, transition},
        opts
      )
    end
  end

  defp claim_generation_conn(conn, session_id, expected, owner_instance_id, operation_id, jidoka_lease_id) do
    with {:ok, current} <- load_generation(conn, session_id),
         :ok <- expect_generation(session_id, expected, current.generation),
         :ok <- reject_generation_overflow(session_id, current.generation) do
      generation = current.generation + 1
      claimed_at_ms = now_ms()

      with :ok <-
             execute(
               conn,
               "INSERT INTO session_generations(session_id,generation,owner_instance_id,claim_operation_id,state,jidoka_lease_id,claimed_at_ms,released_at_ms) VALUES(?,?,?,?,?,?,?,NULL) ON CONFLICT(session_id) DO UPDATE SET generation=excluded.generation,owner_instance_id=excluded.owner_instance_id,claim_operation_id=excluded.claim_operation_id,state='active',jidoka_lease_id=excluded.jidoka_lease_id,claimed_at_ms=excluded.claimed_at_ms,released_at_ms=NULL WHERE session_generations.generation=?",
               [
                 session_id,
                 generation,
                 owner_instance_id,
                 operation_id,
                 "active",
                 jidoka_lease_id,
                 claimed_at_ms,
                 expected
               ]
             ),
           :ok <-
             insert_generation_audit(
               conn,
               operation_id,
               session_id,
               generation,
               owner_instance_id,
               "claimed",
               jidoka_lease_id,
               claimed_at_ms
             ) do
        {:ok,
         generation_value(
           session_id,
           generation,
           owner_instance_id,
           operation_id,
           :active,
           jidoka_lease_id,
           claimed_at_ms,
           nil
         )}
      end
    end
  end

  defp release_generation_conn(conn, fence, operation_id) do
    with {:ok, session_id, generation, owner_instance_id, ^operation_id} <-
           normalize_fence(fence, operation_id),
         {:ok, current} <- load_generation(conn, session_id),
         :ok <- exact_active_generation(current, generation, owner_instance_id),
         released_at_ms = now_ms(),
         :ok <-
           execute(
             conn,
             "UPDATE session_generations SET state='released',released_at_ms=? WHERE session_id=? AND generation=? AND owner_instance_id=? AND state='active'",
             [released_at_ms, session_id, generation, owner_instance_id]
           ),
         :ok <-
           insert_generation_audit(
             conn,
             operation_id,
             session_id,
             generation,
             owner_instance_id,
             "released",
             current.jidoka_lease_id,
             released_at_ms
           ) do
      {:ok,
       generation_value(
         session_id,
         generation,
         owner_instance_id,
         current.claim_operation_id,
         :released,
         current.jidoka_lease_id,
         current.claimed_at_ms,
         released_at_ms
       )}
    else
      {:ok, _session_id, _generation, _owner_instance_id, other_operation_id} ->
        {:error, {:generation_operation_conflict, other_operation_id, operation_id}}

      {:error, _reason} = error ->
        error
    end
  end

  defp load_generation(conn, session_id) do
    sql =
      "SELECT generation,owner_instance_id,claim_operation_id,state,jidoka_lease_id,claimed_at_ms,released_at_ms FROM session_generations WHERE session_id=?"

    case query(conn, sql, [session_id]) do
      {:ok, [[generation, owner, operation, state, lease, claimed, released]]} ->
        {:ok,
         generation_value(
           session_id,
           generation,
           owner,
           operation,
           String.to_existing_atom(state),
           lease,
           claimed,
           released
         )}

      {:ok, []} ->
        {:ok,
         %{
           session_id: session_id,
           generation: 0,
           owner_instance_id: nil,
           claim_operation_id: nil,
           state: :unclaimed,
           jidoka_lease_id: nil,
           claimed_at_ms: nil,
           released_at_ms: nil
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_generation_audit(conn, session_id) do
    sql =
      "SELECT operation_id,generation,owner_instance_id,transition,jidoka_lease_id,occurred_at_ms FROM generation_audit WHERE session_id=? ORDER BY generation,occurred_at_ms,operation_id"

    with {:ok, rows} <- query(conn, sql, [session_id]) do
      {:ok,
       Enum.map(rows, fn [operation, generation, owner, transition, lease, occurred] ->
         %{
           operation_id: operation,
           session_id: session_id,
           generation: generation,
           owner_instance_id: owner,
           transition: String.to_existing_atom(transition),
           jidoka_lease_id: lease,
           occurred_at_ms: occurred
         }
       end)}
    end
  end

  defp insert_generation_audit(
         conn,
         operation_id,
         session_id,
         generation,
         owner_instance_id,
         transition,
         jidoka_lease_id,
         occurred_at_ms
       ) do
    execute(
      conn,
      "INSERT INTO generation_audit(operation_id,session_id,generation,owner_instance_id,transition,jidoka_lease_id,occurred_at_ms) VALUES(?,?,?,?,?,?,?)",
      [operation_id, session_id, generation, owner_instance_id, transition, jidoka_lease_id, occurred_at_ms]
    )
  end

  defp verify_generation_fence(conn, session_id, fence, operation_id) do
    with {:ok, current} <- load_generation(conn, session_id) do
      case current.state do
        :unclaimed ->
          :ok

        _state ->
          with {:ok, fence_session_id, generation, owner_instance_id, ^operation_id} <-
                 normalize_fence(fence, operation_id),
               :ok <- same_fence_session(session_id, fence_session_id),
               :ok <- exact_active_generation(current, generation, owner_instance_id) do
            :ok
          else
            {:ok, _session_id, _generation, _owner_instance_id, other_operation_id} ->
              {:error, {:generation_operation_conflict, other_operation_id, operation_id}}

            {:error, _reason} = error ->
              error
          end
      end
    end
  end

  defp normalize_fence(nil, _operation_id), do: {:error, :generation_fence_required}

  defp normalize_fence(fence, _operation_id) when is_map(fence) do
    session_id = Map.get(fence, :session_id) || Map.get(fence, "session_id")
    generation = Map.get(fence, :generation) || Map.get(fence, "generation")
    owner = Map.get(fence, :owner_instance_id) || Map.get(fence, "owner_instance_id")
    operation = Map.get(fence, :operation_id) || Map.get(fence, "operation_id")

    if valid_token?(session_id) and is_integer(generation) and generation > 0 and valid_token?(owner) and
         valid_token?(operation) do
      {:ok, session_id, generation, owner, operation}
    else
      {:error, :invalid_generation_fence}
    end
  end

  defp normalize_fence(_fence, _operation_id), do: {:error, :invalid_generation_fence}

  defp same_fence_session(session_id, session_id), do: :ok

  defp same_fence_session(session_id, candidate),
    do: {:error, {:cross_session_generation_fence, candidate, session_id}}

  defp exact_active_generation(%{state: :released, session_id: session_id, generation: generation}, _, _),
    do: {:error, {:generation_not_active, session_id, generation}}

  defp exact_active_generation(%{session_id: session_id, generation: current}, candidate, _owner)
       when current != candidate,
       do: {:error, {:stale_generation, session_id, candidate, current}}

  defp exact_active_generation(
         %{session_id: session_id, owner_instance_id: current_owner},
         _generation,
         candidate_owner
       )
       when current_owner != candidate_owner,
       do: {:error, {:generation_owner_conflict, session_id, candidate_owner, current_owner}}

  defp exact_active_generation(%{state: :active}, _generation, _owner), do: :ok

  defp expect_generation(_session_id, expected, expected), do: :ok

  defp expect_generation(session_id, expected, current),
    do: {:error, {:generation_conflict, session_id, expected, current}}

  defp reject_generation_overflow(session_id, @max_generation),
    do: {:error, {:generation_overflow, session_id, @max_generation}}

  defp reject_generation_overflow(_session_id, _generation), do: :ok

  defp generation_value(
         session_id,
         generation,
         owner_instance_id,
         claim_operation_id,
         state,
         jidoka_lease_id,
         claimed_at_ms,
         released_at_ms
       ) do
    %{
      session_id: session_id,
      generation: generation,
      owner_instance_id: owner_instance_id,
      claim_operation_id: claim_operation_id,
      state: state,
      jidoka_lease_id: jidoka_lease_id,
      claimed_at_ms: claimed_at_ms,
      released_at_ms: released_at_ms
    }
  end

  defp admit_operation_conn(conn, prepared, event, semantic) do
    with {:ok, verified} <- verify_prepared_admission(prepared, event),
         {:ok, existing} <- load_admission_by_key(conn, prepared) do
      admit_or_return_operation(conn, existing, verified, prepared, event, semantic)
    end
  end

  defp admit_or_return_operation(
         _conn,
         %{payload_digest: digest} = existing,
         _verified,
         %{payload_digest: digest},
         _event,
         _semantic
       ) do
    {:ok, Map.put(existing, :duplicate, true)}
  end

  defp admit_or_return_operation(
         _conn,
         %{receipt_id: receipt_id},
         _verified,
         _prepared,
         _event,
         _semantic
       ),
       do: {:error, {:idempotency_conflict, receipt_id}}

  defp admit_or_return_operation(conn, nil, verified, prepared, event, semantic) do
    with :ok <- admit_normal_write(conn, verified.encoded_bytes),
         {:ok, event_result} <- append_event_conn(conn, prepared.operation_id, event, semantic),
         :ok <- insert_admission_receipt(conn, prepared, event, verified),
         :ok <- insert_admission_transition(conn, prepared.operation_id, 0, prepared.operation_id, "accepted"),
         {:ok, receipt} <- load_admission_receipt(conn, prepared.operation_id) do
      {:ok, receipt |> Map.put(:duplicate, false) |> Map.put(:event, event_result)}
    end
  end

  defp verify_prepared_admission(prepared, event) do
    with %{bytes: bytes, digest: digest} <- prepared.encoded,
         {:ok, verified} <- Record.decode(bytes),
         true <- verified.digest == digest,
         record = verified.record,
         payload = record["payload"],
         true <- record["record_id"] == prepared.receipt_id,
         true <- record["scope_id"] == event["session_id"],
         true <- record["sequence"] == get_in(event, ["payload", "sequence"]),
         true <- payload["operation_id"] == prepared.operation_id,
         true <- payload["idempotency_key"] == prepared.idempotency_key,
         true <- payload["principal_id"] == prepared.principal_id,
         :ok <- verify_admission_record_payload(prepared, record) do
      {:ok, verified}
    else
      false -> {:error, :invalid_admission_receipt}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_admission_receipt}
    end
  end

  defp verify_admission_record_payload(prepared, %{
         "record_type" => "input_receipt",
         "payload" => payload
       }) do
    if prepared.receipt_type == "input_receipt" and
         payload["payload_digest"] == prepared.payload_digest and
         payload["input_id"] == prepared.target_id and
         payload["admission_state"] == "accepted" and valid_prepared_payload_digest?(prepared) do
      :ok
    else
      {:error, :invalid_admission_receipt}
    end
  end

  defp verify_admission_record_payload(prepared, %{
         "record_type" => "command_receipt",
         "payload" => payload
       }) do
    with true <- prepared.receipt_type == "command_receipt",
         true <- payload["result_id"] == prepared.target_id,
         true <- payload["effective_arguments"] == prepared.normalized_payload,
         true <- valid_prepared_payload_digest?(prepared) do
      :ok
    else
      _other -> {:error, :invalid_admission_receipt}
    end
  end

  defp verify_admission_record_payload(_prepared, _record),
    do: {:error, :invalid_admission_receipt}

  defp valid_prepared_payload_digest?(prepared) do
    value = %{
      "schema" => @admission_schema,
      "operation_kind" => prepared.operation_kind,
      "principal_id" => prepared.principal_id,
      "target_id" => prepared.target_id,
      "payload" => prepared.normalized_payload
    }

    case CanonicalJSON.encode(value) do
      {:ok, bytes} -> Digest.portable(bytes) == prepared.payload_digest
      {:error, _reason} -> false
    end
  end

  defp insert_admission_receipt(conn, prepared, event, verified) do
    record = verified.record

    execute(
      conn,
      "INSERT INTO admission_receipts(receipt_id,operation_id,scope_id,generation,sequence,operation_kind,principal_id,idempotency_key,payload_digest,target_id,event_id,admission_state,record_digest,encoded_bytes,record,committed_at_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
      [
        prepared.receipt_id,
        prepared.operation_id,
        record["scope_id"],
        record["generation"],
        record["sequence"],
        prepared.operation_kind,
        prepared.principal_id,
        prepared.idempotency_key,
        prepared.payload_digest,
        prepared.target_id,
        event["id"],
        "accepted",
        verified.digest,
        verified.encoded_bytes,
        {:blob, verified.bytes},
        now_ms()
      ]
    )
  end

  defp load_admission_by_key(conn, prepared) do
    sql =
      "SELECT operation_id FROM admission_receipts WHERE scope_id=? AND operation_kind=? AND principal_id=? AND idempotency_key=?"

    case query(conn, sql, [
           prepared.encoded.record["scope_id"],
           prepared.operation_kind,
           prepared.principal_id,
           prepared.idempotency_key
         ]) do
      {:ok, [[operation_id]]} -> load_admission_receipt(conn, operation_id)
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_admission_receipt(conn, operation_id) do
    sql =
      "SELECT r.receipt_id,r.scope_id,r.generation,r.sequence,r.operation_kind,r.principal_id,r.idempotency_key,r.payload_digest,r.target_id,r.event_id,(SELECT t.admission_state FROM admission_transitions t WHERE t.operation_id=r.operation_id ORDER BY t.ordinal DESC LIMIT 1),r.record_digest,r.encoded_bytes,r.record,r.committed_at_ms FROM admission_receipts r WHERE r.operation_id=?"

    case query(conn, sql, [operation_id]) do
      {:ok, [row]} -> decode_admission_receipt(operation_id, row)
      {:ok, []} -> {:error, {:admission_receipt_not_found, operation_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_recoverable_admissions(conn, session_id, states, limit) do
    placeholders = Enum.map_join(states, ",", fn _state -> "?" end)

    sql =
      "SELECT r.operation_id,r.receipt_id,r.scope_id,r.generation,r.sequence,r.operation_kind,r.principal_id,r.idempotency_key,r.payload_digest,r.target_id,r.event_id,(SELECT t.admission_state FROM admission_transitions t WHERE t.operation_id=r.operation_id ORDER BY t.ordinal DESC LIMIT 1),r.record_digest,r.encoded_bytes,r.record,r.committed_at_ms FROM admission_receipts r WHERE r.scope_id=? AND (SELECT t.admission_state FROM admission_transitions t WHERE t.operation_id=r.operation_id ORDER BY t.ordinal DESC LIMIT 1) IN (#{placeholders}) ORDER BY r.sequence,r.operation_id LIMIT ?"

    with {:ok, rows} <- query(conn, sql, [session_id | states] ++ [limit]) do
      Enum.reduce_while(rows, {:ok, []}, fn [operation_id | row], {:ok, receipts} ->
        case decode_admission_receipt(operation_id, row) do
          {:ok, receipt} -> {:cont, {:ok, [receipt | receipts]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, receipts} -> {:ok, Enum.reverse(receipts)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp transition_admission_conn(conn, receipt, transition_operation_id, next_state) do
    with {:ok, existing} <- load_admission_transition(conn, transition_operation_id) do
      transition_or_return_admission(conn, receipt, existing, transition_operation_id, next_state)
    end
  end

  defp transition_or_return_admission(
         _conn,
         %{operation_id: operation_id} = receipt,
         %{operation_id: operation_id, admission_state: state},
         _transition_operation_id,
         state
       ),
       do: {:ok, Map.put(receipt, :duplicate, true)}

  defp transition_or_return_admission(
         _conn,
         %{operation_id: operation_id},
         %{operation_id: existing_operation_id},
         transition_operation_id,
         _next_state
       ),
       do:
         {:error,
          {:admission_transition_operation_conflict, transition_operation_id, existing_operation_id, operation_id}}

  defp transition_or_return_admission(
         _conn,
         %{admission_state: state} = receipt,
         nil,
         _transition_operation_id,
         state
       ),
       do: {:ok, Map.put(receipt, :duplicate, true)}

  defp transition_or_return_admission(conn, receipt, nil, transition_operation_id, next_state) do
    with :ok <- valid_admission_transition(receipt.admission_state, next_state),
         {:ok, ordinal} <- next_admission_ordinal(conn, receipt.operation_id),
         :ok <-
           insert_admission_transition(
             conn,
             receipt.operation_id,
             ordinal,
             transition_operation_id,
             next_state
           ),
         {:ok, transitioned} <- load_admission_receipt(conn, receipt.operation_id) do
      {:ok, Map.put(transitioned, :duplicate, false)}
    end
  end

  defp load_admission_transition(conn, transition_operation_id) do
    sql =
      "SELECT operation_id,transition_operation_id,admission_state,ordinal,committed_at_ms FROM admission_transitions WHERE transition_operation_id=?"

    case query(conn, sql, [transition_operation_id]) do
      {:ok, [[operation_id, transition_id, state, ordinal, committed_at_ms]]} ->
        {:ok,
         %{
           operation_id: operation_id,
           transition_operation_id: transition_id,
           admission_state: state,
           ordinal: ordinal,
           committed_at_ms: committed_at_ms
         }}

      {:ok, []} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_admission_ordinal(conn, operation_id) do
    case query(conn, "SELECT COALESCE(MAX(ordinal),-1)+1 FROM admission_transitions WHERE operation_id=?", [
           operation_id
         ]) do
      {:ok, [[ordinal]]} -> {:ok, ordinal}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_admission_transition(conn, operation_id, ordinal, transition_operation_id, state) do
    execute(
      conn,
      "INSERT INTO admission_transitions(operation_id,ordinal,transition_operation_id,admission_state,committed_at_ms) VALUES(?,?,?,?,?)",
      [operation_id, ordinal, transition_operation_id, state, now_ms()]
    )
  end

  defp valid_admission_transition("accepted", next_state) when next_state in ["started", "terminal"], do: :ok
  defp valid_admission_transition("started", "terminal"), do: :ok

  defp valid_admission_transition(current, next_state),
    do: {:error, {:invalid_admission_transition, current, next_state}}

  defp decode_admission_receipt(
         operation_id,
         [
           receipt_id,
           session_id,
           generation,
           sequence,
           kind,
           principal,
           key,
           payload_digest,
           target_id,
           event_id,
           state,
           record_digest,
           encoded_bytes,
           bytes,
           committed_at_ms
         ]
       ) do
    with {:ok, encoded} <- Record.decode(bytes),
         true <- encoded.digest == record_digest,
         true <- encoded.encoded_bytes == encoded_bytes,
         true <- state in ["accepted", "started", "terminal"] do
      {:ok,
       %{
         receipt_id: receipt_id,
         operation_id: operation_id,
         session_id: session_id,
         generation: generation,
         sequence: sequence,
         operation_kind: kind,
         principal_id: principal,
         idempotency_key: key,
         payload_digest: payload_digest,
         target_id: target_id,
         event_id: event_id,
         admission_state: state,
         record_digest: record_digest,
         encoded_bytes: encoded_bytes,
         record: encoded.record,
         committed_at_ms: committed_at_ms
       }}
    else
      false -> {:error, {:admission_receipt_integrity_failed, receipt_id}}
      {:error, _reason} -> {:error, {:admission_receipt_integrity_failed, receipt_id}}
    end
  end

  defp append_event_conn(conn, operation_id, event, semantic) do
    session_id = event["session_id"]
    event_id = event["id"]
    sequence = get_in(event, ["payload", "sequence"])

    with :ok <- validate_event_state(session_id, sequence, semantic),
         {:ok, event_bytes} <- CanonicalJSON.encode(event),
         event_digest = Digest.portable(event_bytes),
         {:ok, duplicate} <- lookup_canonical_event(conn, event_id) do
      append_or_return_event(conn, duplicate, event, event_digest, operation_id, session_id, sequence)
    end
  end

  defp append_or_return_event(_conn, %{event_digest: digest} = existing, _event, digest, _operation, _session, _seq) do
    {:ok, Map.put(existing, :duplicate, true)}
  end

  defp append_or_return_event(_conn, %{event_id: event_id}, _event, _digest, _operation, _session, _seq),
    do: {:error, {:canonical_event_conflict, event_id}}

  defp append_or_return_event(conn, nil, event, event_digest, operation_id, session_id, sequence) do
    with {:ok, head} <- load_optional_history_head(conn, session_id),
         :ok <- expect_history_sequence(session_id, head, sequence),
         prior = if(head, do: head.chain_digest, else: "genesis"),
         generation = event_generation(event),
         {:ok, record} <- canonical_event_record(event, generation, sequence, prior),
         {:ok, encoded} <- Record.encode(record),
         :ok <- admit_normal_write(conn, encoded.encoded_bytes),
         :ok <- admit_record_scope(conn, session_id, "canonical_console_event", encoded.encoded_bytes),
         :ok <- insert_record(conn, encoded),
         :ok <-
           execute(
             conn,
             "INSERT INTO canonical_event_index(event_id,scope_id,sequence,record_id,event_digest) VALUES(?,?,?,?,?)",
             [event["id"], session_id, sequence, record["record_id"], event_digest]
           ),
         suffix_events = if(head, do: head.suffix_events + 1, else: 1),
         suffix_bytes = if(head, do: head.suffix_bytes + encoded.encoded_bytes, else: encoded.encoded_bytes),
         :ok <-
           put_history_head(
             conn,
             session_id,
             generation,
             sequence,
             record["record_id"],
             encoded.digest,
             suffix_events,
             suffix_bytes
           ),
         :ok <- put_receipt(conn, operation_id, "canonical_event", event["id"], encoded.digest) do
      {:ok,
       %{
         event_id: event["id"],
         record_id: record["record_id"],
         sequence: sequence,
         generation: generation,
         chain_digest: encoded.digest,
         encoded_bytes: encoded.encoded_bytes,
         suffix_events: suffix_events,
         suffix_bytes: suffix_bytes,
         duplicate: false
       }}
    end
  end

  defp canonical_event_record(event, generation, sequence, prior) do
    payload = event["payload"]

    with {:ok, origin} <- CanonicalJSON.encode(payload["origin"]),
         {:ok, trust} <- CanonicalJSON.encode(payload["trust"]) do
      {:ok,
       Record.new(
         "canonical_console_event",
         %{
           "event_id" => event["id"],
           "sequence" => sequence,
           "event_class" => event["type"],
           "origin" => origin,
           "trust" => trust,
           "sensitivity" => payload["sensitivity"],
           "event" => event
         },
         record_id: event["id"],
         scope_id: event["session_id"],
         generation: generation,
         sequence: sequence,
         prior_record_digest: prior
       )}
    end
  end

  defp event_generation(event) do
    event
    |> get_in(["payload", "identities"])
    |> List.wrap()
    |> Enum.find_value(1, fn identity ->
      if identity["kind"] == "session", do: identity["generation"] || 1
    end)
  end

  defp validate_event_state(session_id, sequence, semantic) do
    cond do
      semantic.session_id != session_id -> {:error, :cross_session_history}
      semantic.sequence != sequence -> {:error, :semantic_history_sequence_mismatch}
      true -> :ok
    end
  end

  defp lookup_canonical_event(conn, event_id) do
    sql =
      "SELECT i.scope_id,i.sequence,i.record_id,i.event_digest,r.digest,r.encoded_bytes,r.generation FROM canonical_event_index i JOIN records r ON r.record_id=i.record_id WHERE i.event_id=?"

    case query(conn, sql, [event_id]) do
      {:ok, [[scope, sequence, record_id, event_digest, chain_digest, bytes, generation]]} ->
        {:ok,
         %{
           event_id: event_id,
           session_id: scope,
           sequence: sequence,
           record_id: record_id,
           event_digest: event_digest,
           chain_digest: chain_digest,
           encoded_bytes: bytes,
           generation: generation
         }}

      {:ok, []} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_history_head(conn, session_id) do
    case load_optional_history_head(conn, session_id) do
      {:ok, nil} -> {:error, {:history_not_found, session_id}}
      {:ok, head} -> {:ok, head}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_optional_history_head(conn, session_id) do
    sql =
      "SELECT generation,sequence,record_id,chain_digest,suffix_events,suffix_bytes FROM history_heads WHERE scope_id=?"

    case query(conn, sql, [session_id]) do
      {:ok, [[generation, sequence, record_id, digest, suffix_events, suffix_bytes]]} ->
        {:ok,
         %{
           session_id: session_id,
           generation: generation,
           sequence: sequence,
           record_id: record_id,
           chain_digest: digest,
           suffix_events: suffix_events,
           suffix_bytes: suffix_bytes
         }}

      {:ok, []} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expect_history_sequence(_session_id, nil, 1), do: :ok

  defp expect_history_sequence(session_id, nil, sequence),
    do: {:error, {:canonical_event_sequence_conflict, session_id, 1, sequence}}

  defp expect_history_sequence(_session_id, %{sequence: prior}, sequence) when sequence == prior + 1,
    do: :ok

  defp expect_history_sequence(session_id, %{sequence: prior}, sequence),
    do: {:error, {:canonical_event_sequence_conflict, session_id, prior + 1, sequence}}

  defp insert_record(conn, encoded) do
    record = encoded.record

    execute(
      conn,
      "INSERT INTO records(record_id,scope_id,generation,sequence,record_type,prior_digest,digest,encoded_bytes,json) VALUES(?,?,?,?,?,?,?,?,?)",
      [
        record["record_id"],
        record["scope_id"],
        record["generation"],
        record["sequence"],
        record["record_type"],
        record["prior_record_digest"],
        encoded.digest,
        encoded.encoded_bytes,
        {:blob, encoded.bytes}
      ]
    )
  end

  defp put_history_head(conn, session_id, generation, sequence, record_id, digest, suffix_events, suffix_bytes) do
    execute(
      conn,
      "INSERT INTO history_heads(scope_id,generation,sequence,record_id,chain_digest,suffix_events,suffix_bytes) VALUES(?,?,?,?,?,?,?) ON CONFLICT(scope_id) DO UPDATE SET generation=excluded.generation,sequence=excluded.sequence,record_id=excluded.record_id,chain_digest=excluded.chain_digest,suffix_events=excluded.suffix_events,suffix_bytes=excluded.suffix_bytes",
      [session_id, generation, sequence, record_id, digest, suffix_events, suffix_bytes]
    )
  end

  defp put_semantic_snapshot_conn(conn, operation_id, encoded) do
    with {:ok, verified} <- SemanticSnapshot.decode(encoded.bytes, encoded.digest),
         value = verified.value,
         {:ok, head} <- load_history_head(conn, value["session_id"]),
         :ok <- exact_snapshot_source(head, value),
         {:ok, existing} <- lookup_semantic_snapshot(conn, value["snapshot_id"]) do
      put_or_return_semantic_snapshot(conn, existing, verified, operation_id)
    end
  end

  defp put_or_return_semantic_snapshot(_conn, %{digest: digest} = existing, %{digest: digest}, _operation),
    do: {:ok, Map.put(existing, :duplicate, true)}

  defp put_or_return_semantic_snapshot(_conn, %{snapshot_id: snapshot_id}, _encoded, _operation),
    do: {:error, {:semantic_snapshot_conflict, snapshot_id}}

  defp put_or_return_semantic_snapshot(conn, nil, encoded, operation_id) do
    value = encoded.value

    with :ok <- admit_normal_write(conn, encoded.encoded_bytes),
         :ok <-
           execute(
             conn,
             "INSERT INTO semantic_snapshots(snapshot_id,scope_id,generation,source_sequence,source_chain_digest,snapshot_digest,encoded_bytes,snapshot,reason,created_at_ms) VALUES(?,?,?,?,?,?,?,?,?,?)",
             [
               value["snapshot_id"],
               value["session_id"],
               value["generation"],
               value["source_sequence"],
               value["source_chain_digest"],
               encoded.digest,
               encoded.encoded_bytes,
               {:blob, encoded.bytes},
               value["reason"],
               now_ms()
             ]
           ),
         :ok <-
           execute(conn, "UPDATE history_heads SET suffix_events=0,suffix_bytes=0 WHERE scope_id=?", [
             value["session_id"]
           ]),
         :ok <- retain_semantic_snapshots(conn, value["session_id"]),
         :ok <- put_receipt(conn, operation_id, "semantic_snapshot", value["snapshot_id"], encoded.digest) do
      {:ok,
       %{
         snapshot_id: value["snapshot_id"],
         source_sequence: value["source_sequence"],
         source_chain_digest: value["source_chain_digest"],
         digest: encoded.digest,
         encoded_bytes: encoded.encoded_bytes,
         reason: value["reason"],
         duplicate: false
       }}
    end
  end

  defp exact_snapshot_source(head, value) do
    if head.sequence == value["source_sequence"] and head.chain_digest == value["source_chain_digest"] do
      :ok
    else
      {:error, :semantic_snapshot_head_mismatch}
    end
  end

  defp lookup_semantic_snapshot(conn, snapshot_id) do
    sql =
      "SELECT source_sequence,source_chain_digest,snapshot_digest,encoded_bytes,reason FROM semantic_snapshots WHERE snapshot_id=?"

    case query(conn, sql, [snapshot_id]) do
      {:ok, [[sequence, chain, digest, bytes, reason]]} ->
        {:ok,
         %{
           snapshot_id: snapshot_id,
           source_sequence: sequence,
           source_chain_digest: chain,
           digest: digest,
           encoded_bytes: bytes,
           reason: reason
         }}

      {:ok, []} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retain_semantic_snapshots(conn, session_id) do
    execute(
      conn,
      "DELETE FROM semantic_snapshots WHERE scope_id=? AND referenced=0 AND snapshot_id NOT IN (SELECT snapshot_id FROM semantic_snapshots WHERE scope_id=? ORDER BY source_sequence DESC,created_at_ms DESC LIMIT 3)",
      [session_id, session_id]
    )
  end

  defp read_semantic_snapshots(conn, session_id) do
    sql =
      "SELECT snapshot_id,generation,source_sequence,source_chain_digest,snapshot_digest,encoded_bytes,snapshot,reason FROM semantic_snapshots WHERE scope_id=? ORDER BY source_sequence DESC,created_at_ms DESC LIMIT 3"

    with {:ok, rows} <- query(conn, sql, [session_id]) do
      {:ok,
       Enum.map(rows, fn [snapshot_id, generation, sequence, chain, digest, bytes, snapshot, reason] ->
         %{
           snapshot_id: snapshot_id,
           session_id: session_id,
           generation: generation,
           source_sequence: sequence,
           source_chain_digest: chain,
           digest: digest,
           encoded_bytes: bytes,
           bytes: snapshot,
           reason: reason
         }
       end)}
    end
  end

  defp read_history_suffix(conn, session_id, bounds) do
    sql =
      "WITH candidates AS (SELECT i.event_id,i.event_digest,i.sequence,i.record_id,r.digest,r.prior_digest,r.encoded_bytes,SUM(r.encoded_bytes) OVER (ORDER BY i.sequence) AS cumulative_bytes FROM canonical_event_index i JOIN records r ON r.record_id=i.record_id WHERE i.scope_id=? AND i.sequence>? ORDER BY i.sequence LIMIT ?) SELECT r.json,c.digest,c.prior_digest,c.encoded_bytes,c.event_id,c.event_digest,c.sequence FROM candidates c JOIN records r ON r.record_id=c.record_id WHERE c.cumulative_bytes<=? ORDER BY c.sequence"

    with {:ok, rows} <- query(conn, sql, [session_id, bounds.after, bounds.limit + 1, bounds.bytes]),
         true <- length(rows) <= bounds.limit,
         {:ok, records} <- decode_history_rows(rows, bounds.bytes, []) do
      {:ok, records}
    else
      false -> {:error, :history_suffix_limit}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_history_rows([], _remaining, records), do: {:ok, Enum.reverse(records)}

  defp decode_history_rows([[bytes, digest, prior, size, event_id, event_digest, sequence] | rows], remaining, acc)
       when size <= remaining do
    with {:ok, encoded} <- Record.decode(bytes),
         true <- encoded.digest == digest,
         %{"record_type" => "canonical_console_event", "payload" => payload} <- encoded.record,
         event when is_map(event) <- payload["event"],
         true <- payload["event_id"] == event_id and payload["sequence"] == sequence,
         {:ok, event_bytes} <- CanonicalJSON.encode(event),
         true <- Digest.portable(event_bytes) == event_digest do
      record = %{
        event: event,
        event_id: event_id,
        sequence: sequence,
        prior_digest: prior,
        record_digest: digest,
        encoded_bytes: size,
        encoded: encoded
      }

      decode_history_rows(rows, remaining - size, [record | acc])
    else
      false -> {:error, :canonical_history_digest_mismatch}
      _invalid -> {:error, :invalid_canonical_history_record}
    end
  end

  defp decode_history_rows([_row | _rows], _remaining, _records), do: {:error, :history_suffix_limit}

  defp append_record(conn, operation_id, encoded) do
    record = encoded.record
    scope_id = record["scope_id"]
    generation = record["generation"]
    sequence = record["sequence"]

    with :ok <- admit_credential_profile(conn, record),
         :ok <- admit_normal_write(conn, encoded.encoded_bytes),
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

  defp admit_credential_profile(
         conn,
         %{"record_type" => "credential_profile_reference", "scope_id" => scope_id}
       ) do
    with {:ok, [[profile_versions]]} <-
           query(
             conn,
             "SELECT COUNT(*) FROM records WHERE scope_id=? AND record_type='credential_profile_reference'",
             [scope_id]
           ),
         {:ok, [[profile_count]]} <-
           query(
             conn,
             "SELECT COUNT(DISTINCT scope_id) FROM records WHERE record_type='credential_profile_reference'",
             []
           ) do
      cond do
        profile_versions >= @credential_profile_version_limit ->
          {:error, {:credential_profile_version_limit, scope_id, @credential_profile_version_limit}}

        profile_versions == 0 and profile_count >= @credential_profile_limit ->
          {:error, {:credential_profile_limit, @credential_profile_limit}}

        true ->
          :ok
      end
    end
  end

  defp admit_credential_profile(_conn, _record), do: :ok

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

  defp read_credential_profile_records(conn, %{limit: limit, bytes: max_bytes}) do
    sql =
      "SELECT r.json,r.digest,r.encoded_bytes FROM records r WHERE r.record_type='credential_profile_reference' AND NOT EXISTS (SELECT 1 FROM records newer WHERE newer.scope_id=r.scope_id AND newer.generation=r.generation AND newer.record_type='credential_profile_reference' AND newer.sequence>r.sequence) ORDER BY r.scope_id LIMIT ?"

    with {:ok, rows} <- query(conn, sql, [limit]) do
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
    with :ok <- Sqlite3.set_busy_timeout(conn, 250),
         :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=WAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA synchronous=FULL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA foreign_keys=ON"),
         :ok <- Sqlite3.execute(conn, "PRAGMA trusted_schema=OFF"),
         :ok <- Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY"),
         :ok <- Sqlite3.execute(conn, "PRAGMA page_size=#{@page_size}"),
         :ok <- Sqlite3.execute(conn, "PRAGMA max_page_count=#{@max_pages}"),
         :ok <- Sqlite3.execute(conn, "PRAGMA cache_size=-32768"),
         :ok <- Sqlite3.execute(conn, "PRAGMA wal_autocheckpoint=#{@wal_autocheckpoint_pages}"),
         :ok <- Sqlite3.execute(conn, "PRAGMA journal_size_limit=#{@wal_hard_bytes}") do
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
      {"max_page_count", @max_pages},
      {"wal_autocheckpoint", @wal_autocheckpoint_pages},
      {"journal_size_limit", @wal_hard_bytes}
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

  defp verify_admission_receipts(conn) do
    with {:ok, rows} <-
           query(conn, "SELECT receipt_id,record,record_digest FROM admission_receipts ORDER BY scope_id,sequence", []),
         :ok <- verify_admission_record_rows(rows),
         {:ok, transitions} <-
           query(
             conn,
             "SELECT r.operation_id,r.admission_state,t.ordinal,t.transition_operation_id,t.admission_state FROM admission_receipts r LEFT JOIN admission_transitions t ON t.operation_id=r.operation_id ORDER BY r.operation_id,t.ordinal",
             []
           ) do
      verify_admission_transition_rows(transitions)
    end
  end

  defp verify_admission_record_rows(rows) do
    Enum.reduce_while(rows, :ok, fn [receipt_id, bytes, digest], :ok ->
      case Record.decode(bytes) do
        {:ok, %{digest: ^digest}} -> {:cont, :ok}
        _other -> {:halt, {:error, {:admission_receipt_integrity_failed, receipt_id}}}
      end
    end)
  end

  defp verify_admission_transition_rows(rows) do
    rows
    |> Enum.group_by(&hd/1)
    |> Enum.reduce_while(:ok, fn {operation_id, operation_rows}, :ok ->
      case valid_admission_transition_history?(operation_id, operation_rows) do
        true -> {:cont, :ok}
        false -> {:halt, {:error, {:admission_transition_integrity_failed, operation_id}}}
      end
    end)
  end

  defp valid_admission_transition_history?(operation_id, operation_rows) do
    result =
      Enum.reduce_while(operation_rows, {:ok, -1, nil}, fn
        [^operation_id, "accepted", ordinal, transition_id, state], {:ok, prior_ordinal, prior_state} ->
          valid_ordinal = ordinal == prior_ordinal + 1

          valid_state =
            case {ordinal, transition_id, prior_state, state} do
              {0, ^operation_id, nil, "accepted"} -> true
              {_ordinal, _transition_id, "accepted", next} when next in ["started", "terminal"] -> true
              {_ordinal, _transition_id, "started", "terminal"} -> true
              _other -> false
            end

          if valid_ordinal and valid_state,
            do: {:cont, {:ok, ordinal, state}},
            else: {:halt, :error}

        _row, _state ->
          {:halt, :error}
      end)

    match?({:ok, _ordinal, _state}, result)
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
        {:ok, %{type: :regular}} -> Home.check_private(path)
        {:ok, %{type: type}} -> {:error, {:unsafe_store_file, path, type}}
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:store_path_unavailable, path, reason}}
      end
    end
  end

  defp protect_owned_files(path) do
    [path, path <> "-wal", path <> "-shm"]
    |> Enum.reduce_while(:ok, fn owned_path, :ok ->
      case protect_owned_file(owned_path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp protect_owned_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        with :ok <- chmod_store_file(path) do
          Home.check_private(path)
        end

      {:ok, %{type: type}} ->
        {:error, {:unsafe_store_file, path, type}}

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:store_path_unavailable, path, reason}}
    end
  end

  defp chmod_store_file(path) do
    case File.chmod(path, Home.file_mode()) do
      :ok -> :ok
      {:error, reason} -> {:error, {:store_file_permission_failed, path, reason}}
    end
  end

  defp maybe_integrity_gate(conn, opts) do
    if Keyword.get(opts, :integrity_on_open, false) do
      with {:ok, [["ok"]]} <- query(conn, "PRAGMA integrity_check", []),
           :ok <- verify_record_digests(conn),
           :ok <- verify_admission_receipts(conn),
           :ok <- verify_jidoka_digests(conn) do
        :ok
      else
        {:ok, rows} -> {:error, {:sqlite_integrity_failed, rows}}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp checkpoint_wal(conn, path) do
    initial_bytes = file_size(path <> "-wal")

    if initial_bytes >= @wal_soft_bytes do
      with {:ok, [[busy, log_pages, checkpointed_pages]]} <- query(conn, "PRAGMA wal_checkpoint(TRUNCATE)", []) do
        bytes = file_size(path <> "-wal")
        checkpoint = checkpoint_state(busy, bytes)

        {:ok,
         %{
           bytes: bytes,
           checkpoint: checkpoint,
           busy_readers: busy,
           log_pages: log_pages,
           checkpointed_pages: checkpointed_pages,
           soft_limit_bytes: @wal_soft_bytes,
           hard_limit_bytes: @wal_hard_bytes
         }}
      end
    else
      {:ok,
       %{
         bytes: initial_bytes,
         checkpoint: :ready,
         busy_readers: 0,
         log_pages: 0,
         checkpointed_pages: 0,
         soft_limit_bytes: @wal_soft_bytes,
         hard_limit_bytes: @wal_hard_bytes
       }}
    end
  end

  defp checkpoint_state(0, _bytes), do: :ready
  defp checkpoint_state(_busy, bytes) when bytes >= @wal_hard_bytes, do: :blocked
  defp checkpoint_state(_busy, _bytes), do: :busy

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, :enoent} -> 0
      {:error, _reason} -> @wal_hard_bytes
    end
  end

  defp operation_id(opts) do
    case Keyword.fetch(opts, :operation_id) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :operation_id_required}
    end
  end

  defp expected_generation(opts) do
    case Keyword.fetch(opts, :expected_generation) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> {:error, :expected_generation_required}
    end
  end

  defp owner_instance_id(opts) do
    case Keyword.fetch(opts, :owner_instance_id) do
      {:ok, value} when is_binary(value) and value != "" and byte_size(value) <= 256 -> {:ok, value}
      _other -> {:error, :owner_instance_id_required}
    end
  end

  defp optional_token(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" and byte_size(value) <= 256 -> {:ok, value}
      _other -> {:error, {:invalid_generation_token, key}}
    end
  end

  defp valid_token?(value), do: is_binary(value) and value != "" and byte_size(value) <= 256

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

  defp history_bounds(opts) do
    limit = Keyword.get(opts, :limit, @max_limit)
    bytes = Keyword.get(opts, :max_bytes, @default_bytes)
    after_sequence = Keyword.get(opts, :after_sequence, 0)

    if is_integer(limit) and limit > 0 and limit <= @max_limit and is_integer(bytes) and bytes > 0 and
         bytes <= @default_bytes and is_integer(after_sequence) and after_sequence >= 0 do
      {:ok, %{limit: limit, bytes: bytes, after: after_sequence}}
    else
      {:error, :invalid_history_bounds}
    end
  end

  defp profile_bounds(opts) do
    limit = Keyword.get(opts, :limit, @credential_profile_limit)
    bytes = Keyword.get(opts, :max_bytes, @credential_profile_list_bytes)

    if is_integer(limit) and limit > 0 and limit <= @credential_profile_limit and is_integer(bytes) and bytes > 0 and
         bytes <= @credential_profile_list_bytes do
      {:ok, %{limit: limit, bytes: bytes}}
    else
      {:error, :invalid_credential_profile_bounds}
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
