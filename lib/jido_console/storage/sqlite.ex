defmodule Jido.Console.Storage.SQLite do
  @moduledoc "Single-writer SQLite store for Jidoka sessions and Console thread events."

  use GenServer

  @behaviour Jidoka.Session.Store

  alias Exqlite.Sqlite3
  alias Jido.Console.{Digest, Home}
  alias Jido.Console.Session.Event
  alias Jido.Console.Storage.CanonicalJSON
  alias Jidoka.Session.Data
  alias Jidoka.Session.Transitions
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  @database_bytes 1_024 * 1_024 * 1_024
  @page_size 4_096
  @max_pages div(@database_bytes, @page_size)
  @session_bytes 64 * 1_024 * 1_024
  @event_bytes 256 * 1_024
  @default_event_limit 200
  @max_event_limit 1_000
  @store_version 2
  @session_codec_version 1
  @session_codec_tag :jido_console_session
  @closing_types ~w(prompt_removed prompt_succeeded prompt_failed prompt_cancelled prompt_interrupted)
  @store_file_suffixes ["", "-wal", "-shm"]
  @backup_in_progress ".in-progress"

  @schema """
  CREATE TABLE sessions (
    session_id TEXT PRIMARY KEY,
    revision INTEGER NOT NULL CHECK (revision >= 0),
    status TEXT NOT NULL CHECK (status IN ('new','running','hibernated','waiting','finished','cancelled','error')),
    schema_version INTEGER NOT NULL CHECK (schema_version > 0),
    codec_version INTEGER NOT NULL CHECK (codec_version = 1),
    encoded_bytes INTEGER NOT NULL CHECK (encoded_bytes > 0),
    session_term BLOB NOT NULL,
    updated_at_ms INTEGER NOT NULL CHECK (updated_at_ms >= 0)
  ) STRICT;

  CREATE TABLE thread_events (
    thread_id TEXT NOT NULL,
    sequence INTEGER NOT NULL CHECK (sequence > 0),
    event_id TEXT NOT NULL UNIQUE,
    queue_item_id TEXT NOT NULL,
    request_id TEXT NOT NULL,
    event_type TEXT NOT NULL CHECK (
      event_type IN (
        'prompt_queued',
        'prompt_started',
        'prompt_removed',
        'review_presented',
        'prompt_succeeded',
        'prompt_failed',
        'prompt_cancelled',
        'prompt_interrupted'
      )
    ),
    event_schema_version INTEGER NOT NULL CHECK (event_schema_version = 1),
    jidoka_revision INTEGER CHECK (jidoka_revision IS NULL OR jidoka_revision >= 0),
    payload_digest TEXT NOT NULL,
    encoded_bytes INTEGER NOT NULL CHECK (encoded_bytes >= 0),
    payload_json BLOB NOT NULL,
    committed_at_ms INTEGER NOT NULL CHECK (committed_at_ms >= 0),
    PRIMARY KEY (thread_id, sequence),
    FOREIGN KEY (thread_id) REFERENCES sessions(session_id) ON DELETE RESTRICT
  ) STRICT;

  CREATE INDEX thread_events_queue_idx
    ON thread_events(thread_id, queue_item_id, sequence);

  CREATE INDEX thread_events_request_idx
    ON thread_events(thread_id, request_id, sequence);

  CREATE UNIQUE INDEX thread_events_one_start
    ON thread_events(thread_id, queue_item_id)
    WHERE event_type = 'prompt_started';

  CREATE UNIQUE INDEX thread_events_one_close
    ON thread_events(thread_id, queue_item_id)
    WHERE event_type IN (
      'prompt_removed',
      'prompt_succeeded',
      'prompt_failed',
      'prompt_cancelled',
      'prompt_interrupted'
    );
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

  @doc "Returns fixed storage bounds."
  @spec limits() :: map()
  def limits do
    %{
      database_bytes: @database_bytes,
      event_bytes: @event_bytes,
      event_page: @default_event_limit,
      event_page_max: @max_event_limit,
      session_bytes: @session_bytes
    }
  end

  @impl true
  def put_session(%Data{} = session, opts), do: call(opts, {:put_session, session})

  @impl true
  def get_session(session_id, opts) when is_binary(session_id), do: call(opts, {:get_session, session_id})

  @impl true
  def list_sessions(opts), do: call(opts, :list_sessions)

  @impl true
  def claim_session(session_id, %Turn.Request{} = request, opts) when is_binary(session_id) do
    call(opts, {:transition_session, session_id, {:claim, request}, transition_opts(opts)})
  end

  @impl true
  def claim_resume(session_id, opts) when is_binary(session_id) do
    call(opts, {:transition_session, session_id, :resume, transition_opts(opts)})
  end

  @impl true
  def recover_session(session_id, opts) when is_binary(session_id) do
    call(opts, {:transition_session, session_id, :recover, transition_opts(opts)})
  end

  @impl true
  def checkpoint_session(session_id, lease_id, %Snapshot{} = snapshot, opts)
      when is_binary(session_id) and is_binary(lease_id) do
    call(opts, {:transition_session, session_id, {:checkpoint, lease_id, snapshot}, transition_opts(opts)})
  end

  @impl true
  def commit_session(session_id, lease_id, %Data{} = session, opts)
      when is_binary(session_id) and is_binary(lease_id) do
    call(opts, {:transition_session, session_id, {:commit, lease_id, session}, transition_opts(opts)})
  end

  @impl true
  def renew_session(session_id, lease_id, opts)
      when is_binary(session_id) and is_binary(lease_id) do
    call(opts, {:transition_session, session_id, {:renew, lease_id}, transition_opts(opts)})
  end

  @doc "Appends one validated product event."
  @spec append_thread_event(GenServer.server(), Event.t(), keyword()) ::
          {:ok, %{event: Event.t(), duplicate: boolean()}} | {:error, term()}
  def append_thread_event(server, event, opts \\ []) do
    GenServer.call(server, {:append_thread_event, event, event_opts(opts)}, timeout(opts))
  end

  @doc "Returns one bounded newest-first history window in chronological order."
  @spec thread_events(GenServer.server(), String.t(), keyword()) ::
          {:ok, %{events: [Event.t()], history_truncated?: boolean()}} | {:error, term()}
  def thread_events(server, thread_id, opts \\ []) when is_binary(thread_id) do
    with {:ok, bounds} <- event_bounds(opts) do
      GenServer.call(server, {:thread_events, thread_id, bounds}, timeout(opts))
    end
  end

  @doc "Returns all nonterminal accepted items with their stored lifecycle events."
  @spec open_thread_items(GenServer.server(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def open_thread_items(server, thread_id, opts \\ []) when is_binary(thread_id) do
    GenServer.call(server, {:open_thread_items, thread_id}, timeout(opts))
  end

  @doc "Returns all stored events for one public request identity."
  @spec request_events(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def request_events(server, thread_id, request_id, opts \\ [])
      when is_binary(thread_id) and is_binary(request_id) do
    GenServer.call(server, {:request_events, thread_id, request_id}, timeout(opts))
  end

  @doc "Checks schema, SQLite integrity, codecs, sequences, and event lifecycles."
  @spec inspect_store(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_store(server, opts \\ []) do
    GenServer.call(server, :inspect_store, timeout(opts))
  end

  @doc "Returns small storage counts."
  @spec status(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(server, opts \\ []) do
    GenServer.call(server, :status, timeout(opts))
  end

  @impl true
  def init(opts) do
    with {:ok, path} <- store_path(opts),
         :ok <- prepare_path(path),
         :ok <- recover_interrupted_backup(path),
         {:ok, conn} <- open_store(path, opts) do
      {:ok, %{conn: conn, path: path}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn}), do: Sqlite3.close(conn)

  @impl true
  def handle_call({:put_session, %Data{} = session}, _from, state) do
    result = transaction(state.conn, fn -> put_session_conn(state.conn, session) end)
    {:reply, result, state}
  end

  def handle_call({:get_session, session_id}, _from, state) do
    {:reply, load_session(state.conn, session_id), state}
  end

  def handle_call(:list_sessions, _from, state) do
    {:reply, list_sessions_conn(state.conn), state}
  end

  def handle_call({:transition_session, session_id, operation, opts}, _from, state) do
    result = transaction(state.conn, fn -> transition_session_conn(state.conn, session_id, operation, opts) end)
    {:reply, result, state}
  end

  def handle_call({:append_thread_event, event, opts}, _from, state) do
    result = transaction(state.conn, fn -> append_thread_event_conn(state.conn, event, opts) end)
    {:reply, result, state}
  end

  def handle_call({:thread_events, thread_id, bounds}, _from, state) do
    {:reply, read_thread_events(state.conn, thread_id, bounds), state}
  end

  def handle_call({:open_thread_items, thread_id}, _from, state) do
    {:reply, read_open_thread_items(state.conn, thread_id), state}
  end

  def handle_call({:request_events, thread_id, request_id}, _from, state) do
    {:reply, read_request_events(state.conn, thread_id, request_id), state}
  end

  def handle_call(:inspect_store, _from, state) do
    {:reply, inspect_store_conn(state.conn), state}
  end

  def handle_call(:status, _from, state) do
    result =
      with {:ok, [[sessions]]} <- query(state.conn, "SELECT COUNT(*) FROM sessions", []),
           {:ok, [[thread_events]]} <- query(state.conn, "SELECT COUNT(*) FROM thread_events", []),
           {:ok, [[pages]]} <- query(state.conn, "PRAGMA page_count", []) do
        {:ok, %{sessions: sessions, thread_events: thread_events, database_bytes: pages * @page_size}}
      end

    {:reply, result, state}
  end

  defp put_session_conn(conn, %Data{} = incoming) do
    with {:ok, current} <- load_optional_session(conn, incoming.session_id),
         {:ok, %Data{} = updated} <- Transitions.put(current, incoming),
         :ok <- persist_session(conn, updated) do
      {:ok, updated}
    end
  end

  defp transition_session_conn(conn, session_id, operation, opts) do
    with {:ok, %Data{} = current} <- load_session(conn, session_id),
         {:ok, %Data{} = updated} <- apply_transition(current, operation, opts),
         :ok <- persist_session(conn, updated) do
      {:ok, updated}
    end
  end

  defp apply_transition(session, {:claim, request}, opts), do: Transitions.claim(session, request, opts)
  defp apply_transition(session, :resume, opts), do: Transitions.resume(session, opts)
  defp apply_transition(session, :recover, opts), do: Transitions.recover(session, opts)

  defp apply_transition(session, {:checkpoint, lease_id, snapshot}, opts),
    do: Transitions.checkpoint(session, lease_id, snapshot, opts)

  defp apply_transition(session, {:commit, lease_id, completed}, opts),
    do: Transitions.commit(session, lease_id, completed, opts)

  defp apply_transition(session, {:renew, lease_id}, opts), do: Transitions.renew(session, lease_id, opts)

  defp persist_session(conn, %Data{} = session) do
    with {:ok, %Data{} = validated} <- Data.from_input(session),
         {:ok, encoded} <- encode_session(validated),
         :ok <- within_limit(encoded, @session_bytes, :session_too_large) do
      execute(
        conn,
        """
        INSERT INTO sessions(
          session_id,revision,status,schema_version,codec_version,encoded_bytes,session_term,updated_at_ms
        ) VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET
          revision=excluded.revision,
          status=excluded.status,
          schema_version=excluded.schema_version,
          codec_version=excluded.codec_version,
          encoded_bytes=excluded.encoded_bytes,
          session_term=excluded.session_term,
          updated_at_ms=excluded.updated_at_ms
        """,
        [
          validated.session_id,
          validated.revision,
          Atom.to_string(validated.status),
          validated.schema_version,
          @session_codec_version,
          byte_size(encoded),
          {:blob, encoded},
          now_ms()
        ]
      )
    end
  end

  defp load_optional_session(conn, session_id) do
    case load_session(conn, session_id) do
      {:ok, %Data{} = session} -> {:ok, session}
      {:error, {:session_not_found, ^session_id}} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp load_session(conn, session_id) do
    with {:ok, rows} <-
           query(
             conn,
             "SELECT revision,status,schema_version,codec_version,encoded_bytes,session_term FROM sessions WHERE session_id=?",
             [session_id]
           ) do
      case rows do
        [row] -> decode_session_row(session_id, row)
        [] -> {:error, {:session_not_found, session_id}}
        _rows -> {:error, {:session_integrity_failed, session_id, :duplicate_rows}}
      end
    end
  end

  defp list_sessions_conn(conn) do
    with {:ok, rows} <-
           query(
             conn,
             "SELECT session_id,revision,status,schema_version,codec_version,encoded_bytes,session_term FROM sessions ORDER BY session_id",
             []
           ) do
      decode_session_rows(rows, [])
    end
  end

  defp decode_session_rows(
         [[session_id, revision, status, schema_version, codec_version, encoded_bytes, encoded] | rows],
         sessions
       ) do
    case decode_session_row(session_id, [revision, status, schema_version, codec_version, encoded_bytes, encoded]) do
      {:ok, session} -> decode_session_rows(rows, [session | sessions])
      {:error, _reason} = error -> error
    end
  end

  defp decode_session_rows([], sessions), do: {:ok, Enum.reverse(sessions)}
  defp decode_session_rows(_rows, _sessions), do: {:error, :session_integrity_failed}

  defp decode_session_row(
         session_id,
         [revision, status, schema_version, @session_codec_version, encoded_bytes, encoded]
       )
       when is_binary(encoded) and encoded_bytes == byte_size(encoded) do
    with {:ok, %Data{} = session} <- decode_session(encoded),
         true <- session.session_id == session_id,
         true <- session.revision == revision,
         true <- Atom.to_string(session.status) == status,
         true <- session.schema_version == schema_version do
      {:ok, session}
    else
      false -> {:error, {:session_integrity_failed, session_id, :indexed_fields}}
      {:error, reason} -> {:error, {:session_integrity_failed, session_id, reason}}
    end
  end

  defp decode_session_row(session_id, _row),
    do: {:error, {:session_integrity_failed, session_id, :invalid_row}}

  defp encode_session(%Data{} = session) do
    {:ok,
     :erlang.term_to_binary(
       {@session_codec_tag, @session_codec_version, session},
       compressed: 6,
       minor_version: 2
     )}
  rescue
    error -> {:error, {:session_encode_failed, Exception.message(error)}}
  end

  defp decode_session(encoded) do
    case :erlang.binary_to_term(encoded, [:safe]) do
      {@session_codec_tag, @session_codec_version, %Data{} = session} -> Data.from_input(session)
      {@session_codec_tag, version, _value} -> {:error, {:unsupported_session_codec, version}}
      _value -> {:error, :invalid_session_codec}
    end
  rescue
    error -> {:error, {:session_decode_failed, Exception.message(error)}}
  end

  defp append_thread_event_conn(conn, event, opts) do
    with {:ok, %Event{sequence: nil, committed_at_ms: nil} = event} <- Event.validate(event),
         {:ok, payload_json} <- CanonicalJSON.encode(event.payload),
         :ok <- within_limit(payload_json, @event_bytes, :thread_event_too_large),
         {:ok, existing} <- load_event_by_id(conn, event.id) do
      append_or_return_event(conn, existing, event, payload_json, opts)
    else
      {:ok, %Event{}} -> {:error, :thread_event_storage_fields_forbidden}
      {:error, _reason} = error -> error
    end
  end

  defp append_or_return_event(_conn, %Event{} = existing, %Event{} = event, _payload, _opts) do
    if Event.identity(existing) == Event.identity(event),
      do: {:ok, %{event: existing, duplicate: true}},
      else: {:error, {:event_conflict, event.id}}
  end

  defp append_or_return_event(conn, nil, %Event{} = event, payload_json, opts) do
    with {:ok, %Data{}} <- load_session(conn, event.session_id),
         {:ok, lifecycle} <- load_item_lifecycle(conn, event.session_id, event.queue_item_id),
         :ok <- validate_event_lifecycle(event, lifecycle),
         {:ok, sequence} <- next_event_sequence(conn, event.session_id),
         committed_at_ms = clock_ms(opts),
         payload_digest = Digest.portable(payload_json),
         :ok <-
           execute(
             conn,
             """
             INSERT INTO thread_events(
               thread_id,sequence,event_id,queue_item_id,request_id,event_type,event_schema_version,
               jidoka_revision,payload_digest,encoded_bytes,payload_json,committed_at_ms
             ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
             """,
             [
               event.session_id,
               sequence,
               event.id,
               event.queue_item_id,
               event.request_id,
               event.type,
               event.schema_version,
               event.jidoka_revision,
               payload_digest,
               byte_size(payload_json),
               {:blob, payload_json},
               committed_at_ms
             ]
           ) do
      {:ok, %{event: Event.commit(event, sequence, committed_at_ms), duplicate: false}}
    end
  end

  defp load_event_by_id(conn, event_id) do
    with {:ok, rows} <-
           query(
             conn,
             """
             SELECT thread_id,sequence,event_id,queue_item_id,request_id,event_type,event_schema_version,
                    jidoka_revision,payload_digest,encoded_bytes,payload_json,committed_at_ms
             FROM thread_events WHERE event_id=?
             """,
             [event_id]
           ) do
      case rows do
        [row] -> decode_event_row(row)
        [] -> {:ok, nil}
        _rows -> {:error, {:thread_event_integrity_failed, event_id, :duplicate_rows}}
      end
    end
  end

  defp load_item_lifecycle(conn, thread_id, queue_item_id) do
    with {:ok, rows} <-
           query(
             conn,
             "SELECT request_id,event_type FROM thread_events WHERE thread_id=? AND queue_item_id=? ORDER BY sequence",
             [thread_id, queue_item_id]
           ) do
      {:ok, Enum.map(rows, fn [request_id, type] -> {request_id, type} end)}
    end
  end

  defp validate_event_lifecycle(%Event{type: "prompt_queued"}, []), do: :ok

  defp validate_event_lifecycle(%Event{type: "prompt_queued"} = event, _lifecycle),
    do: lifecycle_error(event, :already_queued)

  defp validate_event_lifecycle(%Event{} = event, []), do: lifecycle_error(event, :missing_queued)

  defp validate_event_lifecycle(%Event{} = event, lifecycle) do
    request_ids = lifecycle |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    types = Enum.map(lifecycle, &elem(&1, 1))

    with :ok <- validate_event_identity(event, request_ids),
         :ok <- validate_event_open(event, types) do
      validate_event_transition(event, types)
    end
  end

  defp validate_event_identity(%Event{request_id: request_id}, [request_id]), do: :ok

  defp validate_event_identity(event, _request_ids),
    do: lifecycle_error(event, :request_identity_conflict)

  defp validate_event_open(event, types) do
    if Enum.any?(types, &(&1 in @closing_types)),
      do: lifecycle_error(event, :already_closed),
      else: :ok
  end

  defp validate_event_transition(%Event{type: "prompt_started"} = event, types) do
    if "prompt_started" in types, do: lifecycle_error(event, :already_started), else: :ok
  end

  defp validate_event_transition(%Event{type: "review_presented"} = event, types) do
    require_started(event, types)
  end

  defp validate_event_transition(%Event{type: "prompt_removed"} = event, types) do
    if "prompt_started" in types, do: lifecycle_error(event, :already_started), else: :ok
  end

  defp validate_event_transition(%Event{type: type} = event, types)
       when type in ["prompt_succeeded", "prompt_cancelled"] do
    require_started(event, types)
  end

  defp validate_event_transition(%Event{type: type}, _types) when type in @closing_types, do: :ok

  defp validate_event_transition(event, _types),
    do: lifecycle_error(event, :invalid_transition)

  defp require_started(event, types) do
    if "prompt_started" in types, do: :ok, else: lifecycle_error(event, :not_started)
  end

  defp lifecycle_error(event, reason),
    do: {:error, {:invalid_thread_event_lifecycle, event.queue_item_id, event.type, reason}}

  defp next_event_sequence(conn, thread_id) do
    with {:ok, [[sequence]]} <-
           query(conn, "SELECT COALESCE(MAX(sequence),0) + 1 FROM thread_events WHERE thread_id=?", [thread_id]) do
      {:ok, sequence}
    end
  end

  defp read_thread_events(conn, thread_id, %{limit: limit, before_sequence: before_sequence}) do
    {where, params} =
      if is_integer(before_sequence) do
        {"thread_id=? AND sequence<?", [thread_id, before_sequence, limit + 1]}
      else
        {"thread_id=?", [thread_id, limit + 1]}
      end

    with {:ok, rows} <-
           query(
             conn,
             """
             SELECT thread_id,sequence,event_id,queue_item_id,request_id,event_type,event_schema_version,
                    jidoka_revision,payload_digest,encoded_bytes,payload_json,committed_at_ms
             FROM thread_events WHERE #{where} ORDER BY sequence DESC LIMIT ?
             """,
             params
           ),
         truncated? = length(rows) > limit,
         rows = Enum.take(rows, limit),
         {:ok, events} <- decode_event_rows(rows, []) do
      {:ok, %{events: Enum.reverse(events), history_truncated?: truncated?}}
    end
  end

  defp read_open_thread_items(conn, thread_id) do
    placeholders = Enum.map_join(@closing_types, ",", fn _type -> "?" end)

    with {:ok, rows} <-
           query(
             conn,
             """
             SELECT e.thread_id,e.sequence,e.event_id,e.queue_item_id,e.request_id,e.event_type,
                    e.event_schema_version,e.jidoka_revision,e.payload_digest,e.encoded_bytes,
                    e.payload_json,e.committed_at_ms
             FROM thread_events e
             WHERE e.thread_id=?
               AND NOT EXISTS (
                 SELECT 1 FROM thread_events closed
                 WHERE closed.thread_id=e.thread_id
                   AND closed.queue_item_id=e.queue_item_id
                   AND closed.event_type IN (#{placeholders})
               )
             ORDER BY e.sequence
             """,
             [thread_id | @closing_types]
           ),
         {:ok, events} <- decode_event_rows(rows, []) do
      {:ok, group_open_events(events)}
    end
  end

  defp read_request_events(conn, thread_id, request_id) do
    with {:ok, rows} <-
           query(
             conn,
             """
             SELECT thread_id,sequence,event_id,queue_item_id,request_id,event_type,event_schema_version,
                    jidoka_revision,payload_digest,encoded_bytes,payload_json,committed_at_ms
             FROM thread_events WHERE thread_id=? AND request_id=? ORDER BY sequence
             """,
             [thread_id, request_id]
           ) do
      decode_event_rows(rows, [])
    end
  end

  defp group_open_events(events) do
    {order, grouped} =
      Enum.reduce(events, {[], %{}}, fn event, {order, grouped} ->
        first? = not Map.has_key?(grouped, event.queue_item_id)
        order = if first?, do: order ++ [event.queue_item_id], else: order
        grouped = Map.update(grouped, event.queue_item_id, [event], &(&1 ++ [event]))
        {order, grouped}
      end)

    Enum.map(order, fn queue_item_id ->
      events = Map.fetch!(grouped, queue_item_id)

      %{
        queue_item_id: queue_item_id,
        request_id: hd(events).request_id,
        queued: Enum.find(events, &(&1.type == "prompt_queued")),
        started: Enum.find(events, &(&1.type == "prompt_started")),
        reviews: Enum.filter(events, &(&1.type == "review_presented")),
        events: events
      }
    end)
  end

  defp decode_event_rows([row | rows], events) do
    case decode_event_row(row) do
      {:ok, event} -> decode_event_rows(rows, [event | events])
      {:error, _reason} = error -> error
    end
  end

  defp decode_event_rows([], events), do: {:ok, Enum.reverse(events)}

  defp decode_event_row([
         thread_id,
         sequence,
         event_id,
         queue_item_id,
         request_id,
         event_type,
         schema_version,
         jidoka_revision,
         payload_digest,
         encoded_bytes,
         payload_json,
         committed_at_ms
       ])
       when is_binary(payload_json) and encoded_bytes == byte_size(payload_json) do
    with true <- Digest.portable(payload_json) == payload_digest,
         {:ok, payload} <- CanonicalJSON.decode(payload_json),
         {:ok, event} <-
           Event.new(%{
             id: event_id,
             session_id: thread_id,
             queue_item_id: queue_item_id,
             request_id: request_id,
             type: event_type,
             schema_version: schema_version,
             jidoka_revision: jidoka_revision,
             payload: payload,
             sequence: sequence,
             committed_at_ms: committed_at_ms
           }) do
      {:ok, event}
    else
      false -> {:error, {:thread_event_integrity_failed, event_id, :payload_digest}}
      {:error, reason} -> {:error, {:thread_event_integrity_failed, event_id, reason}}
    end
  end

  defp decode_event_row(row), do: {:error, {:thread_event_integrity_failed, row}}

  defp inspect_store_conn(conn) do
    with {:ok, [["ok"]]} <- query(conn, "PRAGMA integrity_check", []),
         {:ok, []} <- query(conn, "PRAGMA foreign_key_check", []),
         {:ok, ["sessions", "thread_events"]} <- user_tables(conn),
         {:ok, sessions} <- list_sessions_conn(conn),
         {:ok, rows} <- all_event_rows(conn),
         {:ok, events} <- decode_event_rows(rows, []),
         :ok <- verify_event_sequences(events),
         :ok <- verify_event_lifecycles(events) do
      {:ok, %{integrity: :ok, tables: 2, sessions: length(sessions), thread_events: length(events)}}
    else
      {:ok, value} -> {:error, {:sqlite_integrity_failed, value}}
      {:error, _reason} = error -> error
    end
  end

  defp all_event_rows(conn) do
    query(
      conn,
      """
      SELECT thread_id,sequence,event_id,queue_item_id,request_id,event_type,event_schema_version,
             jidoka_revision,payload_digest,encoded_bytes,payload_json,committed_at_ms
      FROM thread_events ORDER BY thread_id,sequence
      """,
      []
    )
  end

  defp verify_event_sequences(events) do
    events
    |> Enum.group_by(& &1.session_id)
    |> Enum.reduce_while(:ok, fn {thread_id, thread_events}, :ok ->
      actual = Enum.map(thread_events, & &1.sequence)
      expected = Enum.to_list(1..length(thread_events)//1)

      if actual == expected,
        do: {:cont, :ok},
        else: {:halt, {:error, {:thread_event_sequence_gap, thread_id, actual}}}
    end)
  end

  defp verify_event_lifecycles(events) do
    events
    |> Enum.group_by(&{&1.session_id, &1.queue_item_id})
    |> Enum.reduce_while(:ok, fn {{_thread_id, _queue_item_id}, item_events}, :ok ->
      case replay_lifecycle(item_events, []) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp replay_lifecycle([event | events], lifecycle) do
    with :ok <- validate_event_lifecycle(event, lifecycle) do
      replay_lifecycle(events, lifecycle ++ [{event.request_id, event.type}])
    end
  end

  defp replay_lifecycle([], _lifecycle), do: :ok

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

  defp open_store(path, opts) do
    case open_current_store(path, opts) do
      {:error, {:storage_schema_reset_required, ^path, version, _tables}} ->
        with :ok <- preserve_legacy_store(path, version),
             do: open_current_store(path, opts)

      result ->
        result
    end
  end

  defp open_current_store(path, opts) do
    case Sqlite3.open(path) do
      {:ok, conn} ->
        case initialize_connection(conn, path, opts) do
          :ok ->
            {:ok, conn}

          {:error, reason} ->
            _result = Sqlite3.close(conn)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp initialize_connection(conn, path, opts) do
    with :ok <- Sqlite3.set_busy_timeout(conn, 250),
         {:ok, schema_state} <- inspect_schema(conn, path),
         :ok <- configure(conn),
         :ok <- bootstrap(conn, schema_state),
         :ok <- protect_owned_files(path) do
      integrity_gate(conn, opts)
    end
  end

  defp inspect_schema(conn, path) do
    with {:ok, tables} <- user_tables(conn),
         {:ok, [[version]]} <- query(conn, "PRAGMA user_version", []) do
      case {tables, version} do
        {[], 0} ->
          {:ok, :empty}

        {["sessions", "thread_events"], @store_version} ->
          {:ok, :current}

        {tables, version} ->
          if "events" in tables or "operations" in tables,
            do: {:error, {:storage_schema_reset_required, path, version, tables}},
            else: {:error, {:unsupported_store_schema, path, version, tables}}
      end
    end
  end

  defp bootstrap(conn, :empty) do
    with :ok <- Sqlite3.execute(conn, @schema) do
      Sqlite3.execute(conn, "PRAGMA user_version=#{@store_version}")
    end
  end

  defp bootstrap(_conn, :current), do: :ok

  defp preserve_legacy_store(path, version) do
    backup = path <> ".schema-#{version}-backup"

    case create_backup_directory(backup) do
      :ok ->
        case create_backup_marker(backup) do
          :ok ->
            with :ok <- move_store_files(path, backup, @store_file_suffixes, []),
                 :ok <- remove_backup_marker(backup) do
              :ok
            else
              {:error, reason} -> backup_failure(path, backup, reason)
            end

          {:error, reason} ->
            case File.rmdir(backup) do
              :ok ->
                backup_failure(path, backup, reason)

              {:error, cleanup_reason} ->
                backup_failure(path, backup, {:store_backup_cleanup_failed, reason, cleanup_reason})
            end
        end

      {:error, :eexist} ->
        {:error, {:storage_schema_backup_exists, path, backup}}

      {:error, reason} ->
        backup_failure(path, backup, reason)
    end
  end

  defp backup_failure(path, backup, reason),
    do: {:error, {:storage_schema_backup_failed, path, backup, reason}}

  defp create_backup_directory(path) do
    case File.mkdir(path) do
      :ok ->
        case File.chmod(path, Home.directory_mode()) do
          :ok ->
            :ok

          {:error, reason} ->
            _result = File.rmdir(path)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_backup_marker(backup) do
    marker = backup_marker(backup)

    with :ok <- write_backup_marker(marker),
         :ok <- protect_owned_file(marker) do
      :ok
    else
      {:error, reason} ->
        _result = remove_backup_marker(backup)
        {:error, reason}
    end
  end

  defp write_backup_marker(marker) do
    with {:ok, device} <- File.open(marker, [:write, :binary, :exclusive]) do
      result =
        with :ok <- IO.binwrite(device, "in-progress\n") do
          :file.sync(device)
        end

      _result = File.close(device)
      result
    end
  end

  defp remove_backup_marker(backup) do
    case File.rm(backup_marker(backup)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp backup_marker(backup), do: Path.join(backup, @backup_in_progress)

  defp recover_interrupted_backup(path) do
    with {:ok, entries} <- File.ls(Path.dirname(path)),
         {:ok, backups} <- interrupted_backups(path, entries) do
      case recover_interrupted_backups(path, backups) do
        :ok -> :ok
        {:error, backup, reason} -> backup_failure(path, backup, reason)
      end
    else
      {:error, reason} -> backup_failure(path, path, reason)
    end
  end

  defp interrupted_backups(path, entries) do
    prefix = Path.basename(path) <> ".schema-"

    entries
    |> Enum.filter(&(String.starts_with?(&1, prefix) and String.ends_with?(&1, "-backup")))
    |> Enum.map(&Path.join(Path.dirname(path), &1))
    |> Enum.reduce_while({:ok, []}, fn backup, {:ok, backups} ->
      case backup_in_progress?(backup) do
        :in_progress -> {:cont, {:ok, [backup | backups]}}
        :complete -> {:cont, {:ok, backups}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp backup_in_progress?(backup) do
    case File.lstat(backup) do
      {:ok, %{type: :directory}} ->
        case File.lstat(backup_marker(backup)) do
          {:ok, %{type: :regular}} -> :in_progress
          {:error, :enoent} -> :complete
          {:ok, %{type: type}} -> {:error, {:unsafe_store_file, backup_marker(backup), type}}
          {:error, reason} -> {:error, {:store_path_unavailable, backup_marker(backup), reason}}
        end

      {:ok, %{type: type}} ->
        {:error, {:unsafe_store_file, backup, type}}

      {:error, reason} ->
        {:error, {:store_path_unavailable, backup, reason}}
    end
  end

  defp recover_interrupted_backups(_path, []), do: :ok

  defp recover_interrupted_backups(path, [backup]) do
    with :ok <- resume_store_files(path, backup, @store_file_suffixes),
         :ok <- remove_backup_marker(backup) do
      :ok
    else
      {:error, reason} -> {:error, backup, reason}
    end
  end

  defp recover_interrupted_backups(_path, backups),
    do: {:error, hd(backups), {:multiple_incomplete_backups, backups}}

  defp resume_store_files(_path, _backup, []), do: :ok

  defp resume_store_files(path, backup, [suffix | suffixes]) do
    source = path <> suffix
    target = Path.join(backup, Path.basename(source))

    case File.lstat(source) do
      {:ok, %{type: :regular}} ->
        case File.lstat(target) do
          {:error, :enoent} ->
            with :ok <- File.rename(source, target),
                 :ok <- protect_owned_file(target) do
              resume_store_files(path, backup, suffixes)
            end

          {:ok, _stat} ->
            {:error, {:store_backup_recovery_conflict, source, target}}

          {:error, reason} ->
            {:error, {:store_path_unavailable, target, reason}}
        end

      {:ok, %{type: type}} ->
        {:error, {:unsafe_store_file, source, type}}

      {:error, :enoent} ->
        resume_missing_store_file(path, backup, source, target, suffix, suffixes)

      {:error, reason} ->
        {:error, {:store_path_unavailable, source, reason}}
    end
  end

  defp resume_missing_store_file(path, backup, source, target, suffix, suffixes) do
    case File.lstat(target) do
      {:ok, %{type: :regular}} ->
        with :ok <- protect_owned_file(target) do
          resume_store_files(path, backup, suffixes)
        end

      {:ok, %{type: type}} ->
        {:error, {:unsafe_store_file, target, type}}

      {:error, :enoent} when suffix == "" ->
        {:error, {:store_backup_recovery_missing, source, target}}

      {:error, :enoent} ->
        resume_store_files(path, backup, suffixes)

      {:error, reason} ->
        {:error, {:store_path_unavailable, target, reason}}
    end
  end

  defp move_store_files(_path, _backup, [], _moved), do: :ok

  defp move_store_files(path, backup, [suffix | suffixes], moved) do
    source = path <> suffix
    target = Path.join(backup, Path.basename(source))

    case File.lstat(source) do
      {:ok, %{type: :regular}} ->
        move_store_file(path, backup, source, target, suffixes, moved)

      {:ok, %{type: type}} ->
        rollback_store_files(backup, moved, {:unsafe_store_file, source, type})

      {:error, :enoent} ->
        move_store_files(path, backup, suffixes, moved)

      {:error, reason} ->
        rollback_store_files(backup, moved, {:store_path_unavailable, source, reason})
    end
  end

  defp move_store_file(path, backup, source, target, suffixes, moved) do
    case File.rename(source, target) do
      :ok ->
        moved = [{source, target} | moved]

        case protect_owned_file(target) do
          :ok -> move_store_files(path, backup, suffixes, moved)
          {:error, reason} -> rollback_store_files(backup, moved, reason)
        end

      {:error, reason} ->
        rollback_store_files(backup, moved, {:store_backup_move_failed, source, target, reason})
    end
  end

  defp protect_owned_file(path) do
    with :ok <- File.chmod(path, Home.file_mode()), do: Home.check_private(path)
  end

  defp rollback_store_files(backup, moved, reason) do
    rollback =
      Enum.reduce_while(moved, :ok, fn {source, target}, :ok ->
        case File.rename(target, source) do
          :ok -> {:cont, :ok}
          {:error, rollback_reason} -> {:halt, {:error, {target, source, rollback_reason}}}
        end
      end)

    case rollback do
      :ok ->
        case remove_backup_marker(backup) do
          :ok ->
            case File.rmdir(backup) do
              :ok -> {:error, reason}
              {:error, cleanup_reason} -> {:error, {:store_backup_cleanup_failed, reason, cleanup_reason}}
            end

          {:error, cleanup_reason} ->
            {:error, {:store_backup_cleanup_failed, reason, cleanup_reason}}
        end

      {:error, rollback_reason} ->
        {:error, {:store_backup_rollback_failed, reason, rollback_reason}}
    end
  end

  defp user_tables(conn) do
    with {:ok, rows} <-
           query(
             conn,
             "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
             []
           ) do
      {:ok, Enum.map(rows, &hd/1)}
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
      :ok ->
        result

      {:error, reason} ->
        _result = Sqlite3.execute(conn, "ROLLBACK")
        {:error, {:sqlite_commit_failed, reason}}
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
    cond do
      String.contains?(reason, "UNIQUE constraint failed") -> {:constraint_conflict, reason}
      String.contains?(reason, "FOREIGN KEY constraint failed") -> {:foreign_key_conflict, reason}
      true -> {:sqlite_error, reason}
    end
  end

  defp normalize_sqlite_error(reason), do: {:sqlite_error, reason}

  defp within_limit(bytes, limit, label) do
    if byte_size(bytes) <= limit,
      do: :ok,
      else: {:error, {label, byte_size(bytes), limit}}
  end

  defp event_bounds(opts) do
    limit = Keyword.get(opts, :limit, @default_event_limit)
    before_sequence = Keyword.get(opts, :before_sequence)

    if is_integer(limit) and limit > 0 and limit <= @max_event_limit and
         (is_nil(before_sequence) or (is_integer(before_sequence) and before_sequence > 0)) do
      {:ok, %{limit: limit, before_sequence: before_sequence}}
    else
      {:error, :invalid_thread_event_bounds}
    end
  end

  defp event_opts(opts), do: Keyword.take(opts, [:clock])

  defp transition_opts(opts),
    do: Keyword.take(opts, [:clock, :lease_ttl_ms, :id_generator, :owner_id])

  defp call(opts, message) do
    opts
    |> fetch_writer!()
    |> GenServer.call(message, timeout(opts))
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp fetch_writer!(opts) do
    case Keyword.fetch(opts, :pid) do
      {:ok, pid} when is_pid(pid) or is_atom(pid) or is_tuple(pid) -> pid
      :error -> raise ArgumentError, "SQLite session store requires :pid"
      {:ok, value} -> raise ArgumentError, "invalid SQLite session store pid: #{inspect(value)}"
    end
  end

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
    Enum.map(@store_file_suffixes, &(path <> &1))
    |> Enum.reduce_while(:ok, fn owned_path, :ok ->
      case File.lstat(owned_path) do
        {:ok, %{type: :regular}} ->
          case protect_owned_file(owned_path) do
            :ok -> {:cont, :ok}
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

  defp clock_ms(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> now_ms()
    end
  end

  defp timeout(opts), do: Keyword.get(opts, :call_timeout, 30_000)
  defp now_ms, do: System.system_time(:millisecond)
end
