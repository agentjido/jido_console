defmodule Jido.Console.Storage.SQLite do
  @moduledoc "Small SQLite owner for events, operations, and credential profiles."

  use GenServer

  alias Exqlite.Sqlite3
  alias Jido.Console.{Digest, Home}
  alias Jido.Console.Session.{Envelope, Event}
  alias Jido.Console.Storage.CanonicalJSON

  @database_bytes 1_024 * 1_024 * 1_024
  @page_size 4_096
  @max_pages div(@database_bytes, @page_size)
  @event_limit 10_000
  @event_bytes 256 * 1_024
  @profile_limit 128
  @profile_version_limit 128
  @profile_bytes 16 * 1_024

  @schema """
  CREATE TABLE IF NOT EXISTS events (
    session_id TEXT NOT NULL,
    sequence INTEGER NOT NULL CHECK (sequence > 0),
    event_id TEXT NOT NULL UNIQUE,
    event_type TEXT NOT NULL,
    digest TEXT NOT NULL,
    encoded_bytes INTEGER NOT NULL,
    json BLOB NOT NULL,
    committed_at_ms INTEGER NOT NULL,
    PRIMARY KEY (session_id, sequence)
  ) STRICT;
  CREATE TABLE IF NOT EXISTS operations (
    operation_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    sequence INTEGER NOT NULL CHECK (sequence > 0),
    operation_kind TEXT NOT NULL,
    principal_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    payload_digest TEXT NOT NULL,
    target_id TEXT NOT NULL,
    receipt_id TEXT NOT NULL UNIQUE,
    receipt_type TEXT NOT NULL CHECK (receipt_type IN ('input', 'command')),
    payload BLOB NOT NULL,
    admission_state TEXT NOT NULL CHECK (admission_state IN ('accepted', 'started', 'terminal')),
    event_id TEXT NOT NULL UNIQUE,
    committed_at_ms INTEGER NOT NULL,
    UNIQUE (session_id, operation_kind, principal_id, idempotency_key),
    FOREIGN KEY (session_id, sequence) REFERENCES events(session_id, sequence),
    FOREIGN KEY (event_id) REFERENCES events(event_id)
  ) STRICT;
  CREATE TABLE IF NOT EXISTS credential_profiles (
    profile_id TEXT NOT NULL,
    version INTEGER NOT NULL CHECK (version > 0),
    operation_id TEXT NOT NULL UNIQUE,
    digest TEXT NOT NULL,
    encoded_bytes INTEGER NOT NULL,
    json BLOB NOT NULL,
    committed_at_ms INTEGER NOT NULL,
    PRIMARY KEY (profile_id, version)
  ) STRICT;
  """

  @type option :: {:name, GenServer.name()} | {:path, Path.t()} | {:jido_home, Path.t()}

  @doc "Starts the one writable SQLite owner."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Returns the database path without creating it."
  @spec default_path(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def default_path(opts \\ []) do
    with {:ok, state} <- Home.path(:state, opts) do
      {:ok, Path.join(state, "console.sqlite3")}
    end
  end

  @doc "Returns the fixed store limits."
  @spec limits() :: map()
  def limits do
    %{
      database_bytes: @database_bytes,
      event_bytes: @event_bytes,
      session_events: @event_limit,
      credential_profiles: @profile_limit,
      credential_profile_versions: @profile_version_limit,
      credential_profile_bytes: @profile_bytes
    }
  end

  @doc "Appends one ordered event."
  @spec append_event(GenServer.server(), Envelope.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def append_event(server, event, opts \\ []) do
    GenServer.call(server, {:append_event, event}, timeout(opts))
  end

  @doc "Commits one operation and its event in one transaction."
  @spec admit_operation(GenServer.server(), map(), Envelope.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def admit_operation(server, prepared, event, opts \\ []) do
    GenServer.call(server, {:admit_operation, prepared, event}, timeout(opts))
  end

  @doc "Returns one operation."
  @spec operation(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def operation(server, operation_id, opts \\ []) do
    GenServer.call(server, {:operation, operation_id}, timeout(opts))
  end

  @doc "Changes one operation state."
  @spec transition_operation(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def transition_operation(server, operation_id, state, opts \\ []) do
    GenServer.call(server, {:transition_operation, operation_id, state}, timeout(opts))
  end

  @doc "Returns bounded operations for one session."
  @spec operations(GenServer.server(), String.t(), [String.t()], pos_integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def operations(server, session_id, states, limit, opts \\ []) do
    GenServer.call(server, {:operations, session_id, states, limit}, timeout(opts))
  end

  @doc "Returns all ordered events for one session."
  @spec events(GenServer.server(), String.t(), keyword()) :: {:ok, [Envelope.t()]} | {:error, term()}
  def events(server, session_id, opts \\ []) do
    GenServer.call(server, {:events, session_id}, timeout(opts))
  end

  @doc "Returns the last event identity for one session."
  @spec history_head(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def history_head(server, session_id, opts \\ []) do
    GenServer.call(server, {:history_head, session_id}, timeout(opts))
  end

  @doc "Stores one credential profile version."
  @spec put_profile(GenServer.server(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def put_profile(server, profile, operation_id, opts \\ []) do
    GenServer.call(server, {:put_profile, profile, operation_id}, timeout(opts))
  end

  @doc "Returns all versions of one credential profile."
  @spec profile_history(GenServer.server(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def profile_history(server, profile_id, opts \\ []) do
    GenServer.call(server, {:profile_history, profile_id}, timeout(opts))
  end

  @doc "Returns the latest version of each credential profile."
  @spec profiles(GenServer.server(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def profiles(server, opts \\ []) do
    GenServer.call(server, :profiles, timeout(opts))
  end

  @doc "Checks SQLite and stored payload integrity."
  @spec inspect_store(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_store(server, opts \\ []) do
    GenServer.call(server, :inspect_store, timeout(opts))
  end

  @doc "Returns small store counts."
  @spec status(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(server, opts \\ []) do
    GenServer.call(server, :status, timeout(opts))
  end

  @impl true
  def init(opts) do
    with {:ok, path} <- store_path(opts),
         :ok <- prepare_path(path),
         {:ok, conn} <- Sqlite3.open(path),
         :ok <- Sqlite3.set_busy_timeout(conn, 250),
         :ok <- configure(conn),
         :ok <- bootstrap(conn),
         :ok <- protect_owned_files(path),
         :ok <- integrity_gate(conn, opts) do
      {:ok, %{conn: conn, path: path}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn}), do: Sqlite3.close(conn)

  @impl true
  def handle_call({:append_event, event}, _from, state) do
    result = transaction(state.conn, fn -> append_event_conn(state.conn, event) end)
    {:reply, result, state}
  end

  def handle_call({:admit_operation, prepared, event}, _from, state) do
    result = transaction(state.conn, fn -> admit_operation_conn(state.conn, prepared, event) end)
    {:reply, result, state}
  end

  def handle_call({:operation, operation_id}, _from, state) do
    {:reply, load_operation(state.conn, operation_id), state}
  end

  def handle_call({:transition_operation, operation_id, next}, _from, state) do
    result = transaction(state.conn, fn -> transition_operation_conn(state.conn, operation_id, next) end)
    {:reply, result, state}
  end

  def handle_call({:operations, session_id, states, limit}, _from, state) do
    {:reply, read_operations(state.conn, session_id, states, limit), state}
  end

  def handle_call({:events, session_id}, _from, state) do
    {:reply, read_events(state.conn, session_id), state}
  end

  def handle_call({:history_head, session_id}, _from, state) do
    {:reply, load_history_head(state.conn, session_id), state}
  end

  def handle_call({:put_profile, profile, operation_id}, _from, state) do
    result = transaction(state.conn, fn -> put_profile_conn(state.conn, profile, operation_id) end)
    {:reply, result, state}
  end

  def handle_call({:profile_history, profile_id}, _from, state) do
    {:reply, read_profile_history(state.conn, profile_id), state}
  end

  def handle_call(:profiles, _from, state) do
    {:reply, read_profiles(state.conn), state}
  end

  def handle_call(:inspect_store, _from, state) do
    result =
      with {:ok, [["ok"]]} <- query(state.conn, "PRAGMA integrity_check", []),
           {:ok, _events} <- verify_all_events(state.conn),
           {:ok, _profiles} <- verify_all_profiles(state.conn) do
        {:ok, %{integrity: :ok, tables: 3}}
      else
        {:ok, value} -> {:error, {:sqlite_integrity_failed, value}}
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  def handle_call(:status, _from, state) do
    result =
      with {:ok, [[events]]} <- query(state.conn, "SELECT COUNT(*) FROM events", []),
           {:ok, [[operations]]} <- query(state.conn, "SELECT COUNT(*) FROM operations", []),
           {:ok, [[profiles]]} <- query(state.conn, "SELECT COUNT(*) FROM credential_profiles", []),
           {:ok, [[pages]]} <- query(state.conn, "PRAGMA page_count", []) do
        {:ok, %{events: events, operations: operations, profiles: profiles, database_bytes: pages * @page_size}}
      end

    {:reply, result, state}
  end

  defp append_event_conn(conn, event) do
    with {:ok, event} <- Event.validate(event),
         {:ok, bytes} <- CanonicalJSON.encode(event),
         :ok <- within_limit(bytes, @event_bytes, :event_too_large),
         digest = Digest.portable(bytes),
         {:ok, existing} <- load_event_by_id(conn, event.id) do
      append_or_return_event(conn, existing, event, bytes, digest)
    end
  end

  defp append_or_return_event(_conn, %{digest: digest} = existing, _event, _bytes, digest) do
    {:ok, Map.put(existing, :duplicate, true)}
  end

  defp append_or_return_event(_conn, %{event_id: event_id}, _event, _bytes, _digest) do
    {:error, {:canonical_event_conflict, event_id}}
  end

  defp append_or_return_event(conn, nil, event, bytes, digest) do
    session_id = event.session_id
    sequence = event.payload["sequence"]

    with :ok <- expect_next_sequence(conn, session_id, sequence),
         :ok <- enforce_session_limit(conn, session_id),
         committed_at_ms = now_ms(),
         :ok <-
           execute(
             conn,
             "INSERT INTO events(session_id,sequence,event_id,event_type,digest,encoded_bytes,json,committed_at_ms) VALUES(?,?,?,?,?,?,?,?)",
             [session_id, sequence, event.id, event.type, digest, byte_size(bytes), {:blob, bytes}, committed_at_ms]
           ) do
      {:ok,
       %{
         session_id: session_id,
         sequence: sequence,
         event_id: event.id,
         event_type: event.type,
         digest: digest,
         chain_digest: digest,
         encoded_bytes: byte_size(bytes),
         committed_at_ms: committed_at_ms,
         duplicate: false
       }}
    end
  end

  defp admit_operation_conn(conn, prepared, event) do
    with :ok <- validate_prepared_operation(prepared, event),
         {:ok, existing} <- load_operation_by_key(conn, prepared),
         {:ok, by_id} <- load_optional_operation(conn, prepared.operation_id) do
      admit_or_return_operation(conn, existing || by_id, prepared, event)
    end
  end

  defp admit_or_return_operation(
         _conn,
         %{payload_digest: digest, target_id: target} = existing,
         %{payload_digest: digest, target_id: target},
         _event
       ) do
    {:ok, Map.put(existing, :duplicate, true)}
  end

  defp admit_or_return_operation(_conn, existing, _prepared, _event) when is_map(existing) do
    {:error, {:idempotency_conflict, existing.receipt_id}}
  end

  defp admit_or_return_operation(conn, nil, prepared, event) do
    with {:ok, event_result} <- append_event_conn(conn, event),
         false <- event_result.duplicate,
         {:ok, payload} <- CanonicalJSON.encode(prepared.normalized_payload),
         committed_at_ms = now_ms(),
         :ok <-
           execute(
             conn,
             "INSERT INTO operations(operation_id,session_id,sequence,operation_kind,principal_id,idempotency_key,payload_digest,target_id,receipt_id,receipt_type,payload,admission_state,event_id,committed_at_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
             [
               prepared.operation_id,
               prepared.session_id,
               prepared.sequence,
               prepared.operation_kind,
               prepared.principal_id,
               prepared.idempotency_key,
               prepared.payload_digest,
               prepared.target_id,
               prepared.receipt_id,
               prepared.receipt_type,
               {:blob, payload},
               "accepted",
               event.id,
               committed_at_ms
             ]
           ),
         {:ok, operation} <- load_operation(conn, prepared.operation_id) do
      {:ok, operation |> Map.put(:event, event_result) |> Map.put(:duplicate, false)}
    else
      true -> {:error, :admission_event_already_committed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transition_operation_conn(conn, operation_id, next) do
    with {:ok, current} <- load_operation(conn, operation_id),
         :ok <- valid_transition(current.admission_state, next) do
      if current.admission_state == next do
        {:ok, Map.put(current, :duplicate, true)}
      else
        with :ok <- execute(conn, "UPDATE operations SET admission_state=? WHERE operation_id=?", [next, operation_id]),
             {:ok, updated} <- load_operation(conn, operation_id) do
          {:ok, Map.put(updated, :duplicate, false)}
        end
      end
    end
  end

  defp valid_transition(state, state), do: :ok
  defp valid_transition("accepted", next) when next in ["started", "terminal"], do: :ok
  defp valid_transition("started", "terminal"), do: :ok
  defp valid_transition(current, next), do: {:error, {:invalid_admission_transition, current, next}}

  defp validate_prepared_operation(prepared, event) when is_map(prepared) do
    with {:ok, event} <- Event.validate(event),
         true <- prepared.session_id == event.session_id,
         true <- prepared.sequence == event.payload["sequence"],
         true <- prepared.receipt_type in ["input", "command"],
         true <- is_binary(prepared.operation_id) and prepared.operation_id != "",
         true <- is_binary(prepared.payload_digest) and prepared.payload_digest != "" do
      :ok
    else
      false -> {:error, :invalid_admission_receipt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_prepared_operation(_prepared, _event), do: {:error, :invalid_admission_receipt}

  defp load_event_by_id(conn, event_id) do
    case query(
           conn,
           "SELECT session_id,sequence,event_id,event_type,digest,encoded_bytes,committed_at_ms FROM events WHERE event_id=?",
           [event_id]
         ) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, [[session_id, sequence, id, type, digest, size, committed]]} ->
        {:ok,
         %{
           session_id: session_id,
           sequence: sequence,
           event_id: id,
           event_type: type,
           digest: digest,
           chain_digest: digest,
           encoded_bytes: size,
           committed_at_ms: committed
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_history_head(conn, session_id) do
    case query(
           conn,
           "SELECT sequence,event_id,event_type,digest,encoded_bytes,committed_at_ms FROM events WHERE session_id=? ORDER BY sequence DESC LIMIT 1",
           [session_id]
         ) do
      {:ok, []} ->
        {:error, {:history_not_found, session_id}}

      {:ok, [[sequence, event_id, event_type, digest, size, committed]]} ->
        {:ok,
         %{
           session_id: session_id,
           sequence: sequence,
           event_id: event_id,
           event_type: event_type,
           digest: digest,
           chain_digest: digest,
           encoded_bytes: size,
           committed_at_ms: committed
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_events(conn, session_id) do
    with {:ok, rows} <-
           query(
             conn,
             "SELECT sequence,digest,encoded_bytes,json FROM events WHERE session_id=? ORDER BY sequence LIMIT ?",
             [session_id, @event_limit + 1]
           ),
         true <- length(rows) <= @event_limit do
      decode_event_rows(rows, [])
    else
      false -> {:error, {:session_event_limit_exceeded, session_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_event_rows([[sequence, digest, size, bytes] | rows], events)
       when is_binary(bytes) and size == byte_size(bytes) do
    with true <- Digest.portable(bytes) == digest,
         {:ok, value} <- CanonicalJSON.decode(bytes),
         {:ok, event} <- Event.validate(value),
         true <- event.payload["sequence"] == sequence do
      decode_event_rows(rows, [event | events])
    else
      _other -> {:error, {:event_integrity_failed, sequence}}
    end
  end

  defp decode_event_rows([], events), do: {:ok, Enum.reverse(events)}
  defp decode_event_rows(_rows, _events), do: {:error, :event_integrity_failed}

  defp expect_next_sequence(conn, session_id, sequence) when is_integer(sequence) and sequence > 0 do
    with {:ok, [[current]]} <-
           query(conn, "SELECT COALESCE(MAX(sequence),0) FROM events WHERE session_id=?", [session_id]) do
      if sequence == current + 1,
        do: :ok,
        else: {:error, {:invalid_event_sequence, session_id, current, sequence}}
    end
  end

  defp expect_next_sequence(_conn, session_id, sequence),
    do: {:error, {:invalid_event_sequence, session_id, 0, sequence}}

  defp enforce_session_limit(conn, session_id) do
    with {:ok, [[count]]} <- query(conn, "SELECT COUNT(*) FROM events WHERE session_id=?", [session_id]) do
      if count < @event_limit, do: :ok, else: {:error, {:session_event_limit_exceeded, session_id}}
    end
  end

  defp load_operation_by_key(conn, prepared) do
    case query(
           conn,
           "SELECT operation_id FROM operations WHERE session_id=? AND operation_kind=? AND principal_id=? AND idempotency_key=?",
           [prepared.session_id, prepared.operation_kind, prepared.principal_id, prepared.idempotency_key]
         ) do
      {:ok, []} -> {:ok, nil}
      {:ok, [[operation_id]]} -> load_operation(conn, operation_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_optional_operation(conn, operation_id) do
    case load_operation(conn, operation_id) do
      {:ok, operation} -> {:ok, operation}
      {:error, {:admission_receipt_not_found, ^operation_id}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_operation(conn, operation_id) do
    sql =
      "SELECT operation_id,session_id,sequence,operation_kind,principal_id,idempotency_key,payload_digest,target_id,receipt_id,receipt_type,payload,admission_state,event_id,committed_at_ms FROM operations WHERE operation_id=?"

    case query(conn, sql, [operation_id]) do
      {:ok, []} -> {:error, {:admission_receipt_not_found, operation_id}}
      {:ok, [row]} -> decode_operation_row(row)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_operation_row([
         operation_id,
         session_id,
         sequence,
         kind,
         principal_id,
         key,
         digest,
         target_id,
         receipt_id,
         receipt_type,
         payload,
         state,
         event_id,
         committed
       ]) do
    with {:ok, normalized} <- CanonicalJSON.decode(payload) do
      {:ok,
       %{
         operation_id: operation_id,
         session_id: session_id,
         sequence: sequence,
         operation_kind: kind,
         principal_id: principal_id,
         idempotency_key: key,
         payload_digest: digest,
         target_id: target_id,
         receipt_id: receipt_id,
         receipt_type: receipt_type,
         normalized_payload: normalized,
         admission_state: state,
         event_id: event_id,
         committed_at_ms: committed
       }}
    end
  end

  defp read_operations(conn, session_id, states, limit) do
    placeholders = Enum.map_join(states, ",", fn _state -> "?" end)

    sql =
      "SELECT operation_id,session_id,sequence,operation_kind,principal_id,idempotency_key,payload_digest,target_id,receipt_id,receipt_type,payload,admission_state,event_id,committed_at_ms FROM operations WHERE session_id=? AND admission_state IN (#{placeholders}) ORDER BY sequence LIMIT ?"

    with {:ok, rows} <- query(conn, sql, [session_id | states] ++ [limit]) do
      decode_operation_rows(rows, [])
    end
  end

  defp decode_operation_rows([row | rows], operations) do
    with {:ok, operation} <- decode_operation_row(row) do
      decode_operation_rows(rows, [operation | operations])
    end
  end

  defp decode_operation_rows([], operations), do: {:ok, Enum.reverse(operations)}

  defp put_profile_conn(conn, profile, operation_id) do
    with {:ok, bytes} <- CanonicalJSON.encode(profile),
         :ok <- within_limit(bytes, @profile_bytes, :credential_profile_too_large),
         digest = Digest.portable(bytes),
         {:ok, by_operation} <- load_profile_operation(conn, operation_id),
         {:ok, existing} <- load_profile_row(conn, profile["profile_id"], profile["profile_version"]) do
      put_or_return_profile(conn, by_operation || existing, profile, operation_id, bytes, digest)
    end
  end

  defp put_or_return_profile(
         _conn,
         %{profile_id: id, version: version, digest: digest} = existing,
         %{"profile_id" => id, "profile_version" => version},
         _operation_id,
         _bytes,
         digest
       ) do
    {:ok, Map.put(existing, :duplicate, true)}
  end

  defp put_or_return_profile(_conn, %{operation_id: operation_id}, _profile, operation_id, _bytes, _digest) do
    {:error, {:credential_operation_conflict, operation_id}}
  end

  defp put_or_return_profile(_conn, existing, profile, _operation_id, _bytes, _digest)
       when is_map(existing) do
    {:error, {:credential_profile_version_conflict, existing.version, profile["profile_version"]}}
  end

  defp put_or_return_profile(conn, nil, profile, operation_id, bytes, digest) do
    profile_id = profile["profile_id"]
    version = profile["profile_version"]

    with :ok <- enforce_profile_limits(conn, profile_id, version),
         committed_at_ms = now_ms(),
         :ok <-
           execute(
             conn,
             "INSERT INTO credential_profiles(profile_id,version,operation_id,digest,encoded_bytes,json,committed_at_ms) VALUES(?,?,?,?,?,?,?)",
             [profile_id, version, operation_id, digest, byte_size(bytes), {:blob, bytes}, committed_at_ms]
           ) do
      {:ok,
       %{
         profile_id: profile_id,
         version: version,
         operation_id: operation_id,
         digest: digest,
         encoded_bytes: byte_size(bytes),
         committed_at_ms: committed_at_ms,
         profile: profile,
         duplicate: false
       }}
    end
  end

  defp enforce_profile_limits(conn, profile_id, version) do
    with {:ok, [[profiles]]} <- query(conn, "SELECT COUNT(DISTINCT profile_id) FROM credential_profiles", []),
         {:ok, [[versions]]} <- query(conn, "SELECT COUNT(*) FROM credential_profiles WHERE profile_id=?", [profile_id]) do
      cond do
        versions == 0 and profiles >= @profile_limit -> {:error, :credential_profile_limit_exceeded}
        versions >= @profile_version_limit -> {:error, :credential_profile_version_limit_exceeded}
        version != versions + 1 -> {:error, {:credential_profile_version_conflict, versions + 1, version}}
        true -> :ok
      end
    end
  end

  defp load_profile_operation(conn, operation_id) do
    case query(
           conn,
           "SELECT profile_id,version,operation_id,digest,encoded_bytes,json,committed_at_ms FROM credential_profiles WHERE operation_id=?",
           [operation_id]
         ) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row]} -> decode_profile_row(row)
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_profile_row(conn, profile_id, version) do
    case query(
           conn,
           "SELECT profile_id,version,operation_id,digest,encoded_bytes,json,committed_at_ms FROM credential_profiles WHERE profile_id=? AND version=?",
           [profile_id, version]
         ) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row]} -> decode_profile_row(row)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_profile_history(conn, profile_id) do
    with {:ok, rows} <-
           query(
             conn,
             "SELECT profile_id,version,operation_id,digest,encoded_bytes,json,committed_at_ms FROM credential_profiles WHERE profile_id=? ORDER BY version",
             [profile_id]
           ) do
      decode_profile_rows(rows, [])
    end
  end

  defp read_profiles(conn) do
    sql =
      "SELECT p.profile_id,p.version,p.operation_id,p.digest,p.encoded_bytes,p.json,p.committed_at_ms FROM credential_profiles p JOIN (SELECT profile_id,MAX(version) AS version FROM credential_profiles GROUP BY profile_id) latest ON latest.profile_id=p.profile_id AND latest.version=p.version ORDER BY p.profile_id"

    with {:ok, rows} <- query(conn, sql, []), do: decode_profile_rows(rows, [])
  end

  defp decode_profile_rows([row | rows], profiles) do
    with {:ok, profile} <- decode_profile_row(row) do
      decode_profile_rows(rows, [profile | profiles])
    end
  end

  defp decode_profile_rows([], profiles), do: {:ok, Enum.reverse(profiles)}

  defp decode_profile_row([profile_id, version, operation_id, digest, size, bytes, committed]) do
    with true <- is_binary(bytes) and size == byte_size(bytes),
         true <- Digest.portable(bytes) == digest,
         {:ok, profile} <- CanonicalJSON.decode(bytes) do
      {:ok,
       %{
         profile_id: profile_id,
         version: version,
         operation_id: operation_id,
         digest: digest,
         encoded_bytes: size,
         committed_at_ms: committed,
         profile: profile
       }}
    else
      _other -> {:error, {:credential_profile_integrity_failed, profile_id, version}}
    end
  end

  defp verify_all_events(conn) do
    with {:ok, rows} <-
           query(conn, "SELECT sequence,digest,encoded_bytes,json FROM events ORDER BY session_id,sequence", []) do
      decode_event_rows(rows, [])
    end
  end

  defp verify_all_profiles(conn) do
    with {:ok, rows} <-
           query(
             conn,
             "SELECT profile_id,version,operation_id,digest,encoded_bytes,json,committed_at_ms FROM credential_profiles ORDER BY profile_id,version",
             []
           ) do
      decode_profile_rows(rows, [])
    end
  end

  defp within_limit(bytes, limit, label) do
    if byte_size(bytes) <= limit,
      do: :ok,
      else: {:error, {label, byte_size(bytes), limit}}
  end

  defp configure(conn) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=WAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA synchronous=FULL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA foreign_keys=ON"),
         :ok <- Sqlite3.execute(conn, "PRAGMA trusted_schema=OFF"),
         :ok <- Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY"),
         :ok <- Sqlite3.execute(conn, "PRAGMA page_size=#{@page_size}") do
      Sqlite3.execute(conn, "PRAGMA max_page_count=#{@max_pages}")
    end
  end

  defp bootstrap(conn) do
    with :ok <- Sqlite3.execute(conn, @schema),
         {:ok, [[version]]} <- query(conn, "PRAGMA user_version", []) do
      case version do
        0 -> Sqlite3.execute(conn, "PRAGMA user_version=1")
        1 -> :ok
        other -> {:error, {:unsupported_store_version, other}}
      end
    end
  end

  defp transaction(conn, fun) do
    with :ok <- Sqlite3.execute(conn, "BEGIN IMMEDIATE") do
      case fun.() do
        {:ok, _value} = result -> commit(conn, result)
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

  defp store_path(opts) do
    case Keyword.get(opts, :path) do
      nil ->
        home_opts = Keyword.take(opts, [:jido_home, :user_home])

        with {:ok, _home} <- Home.ensure(home_opts),
             {:ok, state} <- Home.path(:state, home_opts) do
          {:ok, Path.join(state, "console.sqlite3")}
        end

      path when is_binary(path) and path != "" ->
        {:ok, Path.expand(path)}

      path ->
        {:error, {:invalid_sqlite_store_path, path}}
    end
  end

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
      case File.lstat(owned_path) do
        {:ok, %{type: :regular}} ->
          with :ok <- File.chmod(owned_path, Home.file_mode()),
               :ok <- Home.check_private(owned_path) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, {:store_file_permission_failed, owned_path, reason}}}
          end

        {:ok, %{type: type}} ->
          {:halt, {:error, {:unsafe_store_file, owned_path, type}}}

        {:error, :enoent} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:store_path_unavailable, owned_path, reason}}}
      end
    end)
  end

  defp integrity_gate(conn, opts) do
    if Keyword.get(opts, :integrity_on_open, true) do
      case query(conn, "PRAGMA integrity_check", []) do
        {:ok, [["ok"]]} -> :ok
        {:ok, value} -> {:error, {:sqlite_integrity_failed, value}}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp timeout(opts), do: Keyword.get(opts, :call_timeout, 30_000)
  defp now_ms, do: System.system_time(:millisecond)
end
