defmodule Jido.Console.Session.Projection do
  @moduledoc """
  Pure projection of portable Jidoka events into canonical Console events.

  The session owner supplies the Console sequence and owns the returned
  admission cursor. This module owns no process, timer, table, or sequence.

  The complete v1 mapping is:

  * `llm_delta` -> `model_delta`
  * effect and capability start events -> `tool_started`
  * effect, capability, and operation completion events -> `tool_completed`
  * effect and capability failure events -> `tool_failed`
  * `approval_requested` -> `permission_requested`
  * approval response events -> `permission_decided`
  * turn terminal events -> held terminal candidates
  * all other approved Jidoka events -> `run_progress`
  """

  alias Jido.Console.Session.{Event, Identity, Jidoka, Request}

  @max_cursors 64
  @max_recent 64
  @authority_fields ~w(authority permission approval capability principal scope grant)
  @tool_started ~w(effect_planned effect_started capability_call_started)
  @tool_completed ~w(effect_replayed effect_completed capability_call_completed operation_observed)
  @tool_failed ~w(effect_failed capability_call_failed)
  @permission_decided ~w(approval_responded approval_applied)
  @terminal %{
    "turn_finished" => "run_completed",
    "turn_failed" => "run_failed",
    "turn_hibernated" => "run_progress"
  }

  @type digest_entry :: %{
          sequence: non_neg_integer(),
          event_id: String.t(),
          digest: binary()
        }

  @type terminal_state :: %{
          state: :none | :event_pending | :result_pending | :finalized,
          event: map() | nil,
          result: map() | nil
        }

  @type cursor :: %{
          request_id: String.t(),
          last_sequence: integer(),
          recent: [digest_entry()],
          recent_limit: pos_integer(),
          terminal: terminal_state()
        }

  @type result ::
          {:ok, map(), cursor()}
          | {:hold_terminal, map(), cursor()}
          | {:ignore, :duplicate, cursor()}
          | {:error, term(), cursor() | nil}

  @doc "Returns the fixed v1 source-to-Console mapping."
  @spec mapping() :: %{String.t() => String.t() | {:terminal, String.t()}}
  def mapping do
    progress = Map.new(Jidoka.event_names(), &{Atom.to_string(&1), "run_progress"})

    progress
    |> Map.put("llm_delta", "model_delta")
    |> put_types(@tool_started, "tool_started")
    |> put_types(@tool_completed, "tool_completed")
    |> put_types(@tool_failed, "tool_failed")
    |> Map.put("approval_requested", "permission_requested")
    |> put_types(@permission_decided, "permission_decided")
    |> Map.merge(Map.new(@terminal, fn {source, type} -> {source, {:terminal, type}} end))
  end

  @doc "Creates one bounded caller-owned request cursor."
  @spec new_cursor(String.t(), keyword()) :: {:ok, cursor()} | {:error, term()}
  def new_cursor(request_id, opts \\ [])

  def new_cursor(request_id, opts) when is_binary(request_id) and request_id != "" do
    active_count = Keyword.get(opts, :active_cursor_count, 0)
    cursor_limit = bounded_limit(opts, :cursor_limit, @max_cursors)
    recent_limit = bounded_limit(opts, :recent_limit, @max_recent)

    if active_count >= cursor_limit do
      {:error, :projection_cursor_limit}
    else
      {:ok,
       %{
         request_id: request_id,
         last_sequence: -1,
         recent: [],
         recent_limit: recent_limit,
         terminal: %{state: :none, event: nil, result: nil}
       }}
    end
  end

  def new_cursor(_request_id, _opts), do: {:error, :invalid_jidoka_request_identity}

  @doc "Projects one Jidoka event with the caller-owned admission cursor."
  @spec project(term(), keyword()) :: result()
  def project(source, opts) when is_list(opts) do
    cursor = Keyword.get(opts, :cursor)

    with :ok <- reject_closed(opts),
         {:ok, projected} <- portable(source),
         :ok <- validate_projected(projected),
         {:ok, session} <- session_identity(opts),
         {:ok, context} <- owner_context(projected, session, opts),
         {:ok, cursor} <- ensure_cursor(cursor, projected.request_id, opts),
         {:ok, digest, event_id} <- source_digest(projected),
         :ok <- admit_source(cursor, projected, digest, event_id),
         {:ok, candidate} <- candidate(projected, context, event_id, opts) do
      next_cursor = advance(cursor, projected.seq, digest, event_id)

      if projected.terminal? do
        next_cursor = put_terminal_event(next_cursor, candidate)
        {:hold_terminal, candidate, next_cursor}
      else
        case Event.classify(candidate) do
          {:ok, event} -> {:ok, event, next_cursor}
          {:error, reason} -> {:error, bounded_reason(reason), cursor}
        end
      end
    else
      {:duplicate, unchanged} -> {:ignore, :duplicate, unchanged}
      {:error, reason, unchanged} -> {:error, bounded_reason(reason), unchanged}
      {:error, reason} -> {:error, bounded_reason(reason), cursor}
    end
  end

  @doc "Stores one exact, bounded terminal runtime result in a cursor."
  @spec admit_result(cursor(), map(), map()) ::
          {:ok, cursor()} | {:ignore, :duplicate, cursor()} | {:error, term(), cursor()}
  def admit_result(cursor, identity, result)
      when is_map(cursor) and is_map(identity) and is_map(result) do
    with :ok <- validate_result_identity(cursor, identity),
         :ok <- reject_runtime(result),
         :ok <- reject_authority(result),
         {:ok, encoded} <- Jason.encode(result),
         :ok <- require_result_bound(encoded) do
      digest = :crypto.hash(:sha256, encoded)
      stored = %{identity: normalize(identity), value: normalize(result), digest: digest}

      case cursor.terminal.result do
        nil ->
          terminal = %{cursor.terminal | result: stored}
          state = if terminal.event, do: :finalized, else: :result_pending
          {:ok, %{cursor | terminal: %{terminal | state: state}}}

        %{identity: old_identity, digest: ^digest} when old_identity == stored.identity ->
          {:ignore, :duplicate, cursor}

        _old ->
          {:error, :terminal_result_conflict, cursor}
      end
    else
      {:error, reason} -> {:error, bounded_reason(reason), cursor}
    end
  end

  @doc "Builds the one final Console event after event-result arbitration."
  @spec finalize(cursor(), keyword()) :: {:ok, map(), cursor()} | {:error, term(), cursor()}
  def finalize(cursor, opts \\ [])

  def finalize(%{terminal: %{event: event, result: %{value: result}}} = cursor, opts)
      when is_map(event) and is_map(result) do
    shared = ~w(id session_id sequence durability sensitivity origin trust identities)

    attrs =
      event
      |> normalize()
      |> Map.take(shared)
      |> Map.put("type", result[:type] || result["type"] || event[:type] || event["type"])
      |> Map.put("sequence", Keyword.get(opts, :sequence, event[:sequence] || event["sequence"]))
      |> Map.merge(result[:fields] || result["fields"] || %{})

    case Event.classify(attrs) do
      {:ok, final} ->
        terminal = %{cursor.terminal | state: :finalized}
        {:ok, final, %{cursor | terminal: terminal}}

      {:error, reason} ->
        {:error, bounded_reason(reason), cursor}
    end
  end

  def finalize(cursor, _opts), do: {:error, :terminal_not_ready, cursor}

  @doc "Returns true when both sides of terminal arbitration are present."
  @spec terminal_ready?(cursor()) :: boolean()
  def terminal_ready?(%{terminal: %{event: event, result: result}}),
    do: is_map(event) and is_map(result)

  def terminal_ready?(_cursor), do: false

  defp portable(%{__struct__: _module} = source), do: Jidoka.project_events(source)

  defp portable(%{request_id: request_id, seq: seq, event: event} = projected)
       when is_binary(request_id) and is_integer(seq) and (is_binary(event) or is_atom(event)) do
    {:ok, normalize_projection(projected)}
  end

  defp portable(source), do: Jidoka.project_events(source)

  defp validate_projected(projected) do
    event_names = MapSet.new(Jidoka.event_names(), &Atom.to_string/1)

    with :ok <- reject_runtime(projected),
         :ok <- reject_authority(projected[:data] || %{}) do
      cond do
        not is_binary(projected.request_id) or projected.request_id == "" ->
          {:error, :invalid_jidoka_request_identity}

        not is_integer(projected.seq) or projected.seq < 0 ->
          {:error, :invalid_source_sequence}

        not MapSet.member?(event_names, projected.event) ->
          {:error, {:unsupported_jidoka_event, projected.event}}

        true ->
          :ok
      end
    end
  end

  defp reject_closed(opts) do
    closed = Keyword.get(opts, :closed_requests, MapSet.new())
    request_id = Keyword.get(opts, :jidoka_request_id)

    if is_binary(request_id) and MapSet.member?(closed, request_id),
      do: {:error, :stale_source_event},
      else: :ok
  end

  defp ensure_cursor(nil, request_id, opts), do: new_cursor(request_id, opts)

  defp ensure_cursor(%{request_id: request_id} = cursor, request_id, _opts),
    do: {:ok, cursor}

  defp ensure_cursor(_cursor, _request_id, _opts),
    do: {:error, :jidoka_request_identity_mismatch}

  defp admit_source(cursor, projected, digest, event_id) do
    existing = Enum.find(cursor.recent, &(&1.sequence == projected.seq))

    case {cursor.terminal.event, existing} do
      {event, nil} when is_map(event) ->
        {:error, :stale_source_event, cursor}

      {_terminal, %{event_id: ^event_id, digest: ^digest}} ->
        {:duplicate, cursor}

      {_terminal, %{sequence: _sequence}} ->
        {:error, :source_event_conflict, cursor}

      {_terminal, nil} when projected.seq <= cursor.last_sequence ->
        {:error, :stale_source_event, cursor}

      {_terminal, nil} when projected.seq != cursor.last_sequence + 1 ->
        {:error, :source_sequence_gap, cursor}

      {_terminal, nil} ->
        :ok
    end
  end

  defp source_digest(projected) do
    normalized = normalize(projected)

    case Jason.encode(normalized) do
      {:ok, encoded} ->
        digest = :crypto.hash(:sha256, encoded)
        id_digest = :crypto.hash(:sha256, projected.request_id <> ":" <> Integer.to_string(projected.seq))
        event_id = "jsk_" <> Base.url_encode64(id_digest, padding: false)
        {:ok, digest, event_id}

      {:error, _reason} ->
        {:error, :nonportable_projection}
    end
  end

  defp advance(cursor, sequence, digest, event_id) do
    entry = %{sequence: sequence, event_id: event_id, digest: digest}
    recent = Enum.take(cursor.recent ++ [entry], -cursor.recent_limit)
    %{cursor | last_sequence: sequence, recent: recent}
  end

  defp candidate(projected, context, event_id, opts) do
    type = Map.fetch!(mapping(), projected.event)
    type = if match?({:terminal, _}, type), do: elem(type, 1), else: type

    attrs =
      %{
        type: type,
        id: canonical_event_id(event_id, context.console_request_id),
        session_id: context.session.id,
        sequence: Keyword.fetch!(opts, :sequence),
        durability: "process",
        sensitivity: sensitivity(projected),
        origin: %{kind: "jidoka", actor_id: projected.request_id},
        trust: %{evidence: "jidoka-projection", policy: "session-owner"},
        identities: identities(projected, context, event_id)
      }
      |> Map.merge(protocol_fields(type, projected, context))

    case reject_runtime(attrs) do
      :ok -> {:ok, attrs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_event_id(event_id, console_request_id) do
    digest = :crypto.hash(:sha256, event_id <> ":" <> console_request_id)
    "plt_" <> Base.url_encode64(digest, padding: false)
  end

  defp protocol_fields("model_delta", projected, context) do
    %{text: data(projected, "delta") || data(projected, "text") || "", run_id: context.run_id}
  end

  defp protocol_fields("tool_started", projected, context) do
    %{
      run_id: context.run_id,
      step_id: projected[:effect_id] || source_step_id(projected),
      operation: projected[:operation] || data(projected, "operation") || "unknown"
    }
  end

  defp protocol_fields("tool_completed", projected, context) do
    %{
      run_id: context.run_id,
      step_id: projected[:effect_id] || source_step_id(projected),
      content: data(projected, "content") || progress(projected)
    }
  end

  defp protocol_fields("tool_failed", projected, context) do
    %{
      run_id: context.run_id,
      step_id: projected[:effect_id] || source_step_id(projected),
      reason: projected[:error] || data(projected, "reason") || projected[:status] || "failed"
    }
  end

  defp protocol_fields("permission_requested", projected, _context) do
    %{
      approval_id: projected[:effect_id] || source_step_id(projected),
      principal: "session-client",
      scope: projected[:operation] || data(projected, "operation") || "runtime-effect"
    }
  end

  defp protocol_fields("permission_decided", projected, _context) do
    %{
      approval_id: projected[:effect_id] || source_step_id(projected),
      decision: data(projected, "decision") || projected[:status] || "completed"
    }
  end

  defp protocol_fields("run_completed", projected, context) do
    %{outcome_id: context.console_request_id, run_id: context.run_id, content: data(projected, "content")}
  end

  defp protocol_fields("run_failed", projected, context) do
    %{
      reason: projected[:error] || data(projected, "reason") || projected[:status] || "failed",
      run_id: context.run_id
    }
  end

  defp protocol_fields("run_progress", projected, context) do
    %{summary: progress(projected), run_id: context.run_id}
  end

  defp owner_context(projected, session, opts) do
    case Keyword.get(opts, :request) do
      %Request{} = request ->
        cond do
          request.session_id != session.id -> {:error, :cross_session_result}
          request.request_id != projected.request_id -> {:error, :jidoka_request_identity_mismatch}
          true -> {:ok, %{session: session, console_request_id: request.id, run_id: request.run_id}}
        end

      nil ->
        {:ok,
         %{
           session: session,
           console_request_id: Keyword.get(opts, :console_request_id, projected.request_id),
           run_id: Keyword.get(opts, :run_id, projected[:turn_id] || projected.request_id)
         }}

      _invalid ->
        {:error, :invalid_console_request_identity}
    end
  end

  defp identities(projected, context, event_id) do
    base = [
      Identity.to_protocol(context.session),
      protocol_identity("request", context.console_request_id, context.session.id),
      protocol_identity("run", context.run_id, context.session.id),
      protocol_identity("jidoka_request", projected.request_id, context.session.id),
      protocol_identity("source_event", event_id, context.session.id)
    ]

    base
    |> maybe_identity("turn", projected[:turn_id], context.session.id)
    |> maybe_identity("step", projected[:effect_id], context.session.id)
  end

  defp protocol_identity(kind, id, session_id),
    do: %{"kind" => kind, "id" => id, "session_id" => session_id}

  defp maybe_identity(identities, _kind, nil, _session_id), do: identities

  defp maybe_identity(identities, kind, id, session_id),
    do: identities ++ [protocol_identity(kind, id, session_id)]

  defp put_terminal_event(cursor, candidate) do
    terminal = %{cursor.terminal | event: candidate}
    state = if terminal.result, do: :finalized, else: :event_pending
    %{cursor | terminal: %{terminal | state: state}}
  end

  defp validate_result_identity(cursor, identity) do
    request_id = identity[:request_id] || identity["request_id"]

    if request_id == cursor.request_id,
      do: :ok,
      else: {:error, :terminal_result_identity_mismatch}
  end

  defp sensitivity(projected) do
    if contains_redaction?(projected), do: "redacted", else: "public"
  end

  defp contains_redaction?("[REDACTED]"), do: true

  defp contains_redaction?(value) when is_map(value),
    do: Enum.any?(value, fn {_key, item} -> contains_redaction?(item) end)

  defp contains_redaction?(value) when is_list(value), do: Enum.any?(value, &contains_redaction?/1)
  defp contains_redaction?(_value), do: false

  defp progress(projected) do
    %{
      "event" => projected.event,
      "status" => projected[:status],
      "category" => projected[:category],
      "phase" => projected[:phase],
      "data" => projected[:data] || %{}
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp data(projected, key), do: get_in(projected, [:data, key])

  defp source_step_id(projected),
    do: "jsk_step_#{projected.request_id}_#{projected.seq}"

  defp session_identity(opts) do
    case Keyword.fetch(opts, :session) do
      {:ok, %{kind: :session, id: id, session_id: id} = session} when is_binary(id) and id != "" ->
        {:ok, session}

      {:ok, _invalid} ->
        {:error, :invalid_session_identity}

      :error ->
        case Keyword.fetch(opts, :session_id) do
          {:ok, session_id} -> Identity.new(:session, id: session_id)
          :error -> {:error, :session_identity_missing}
        end
    end
  end

  defp reject_runtime(value) when is_pid(value) or is_reference(value) or is_function(value) or is_port(value),
    do: {:error, :raw_runtime_forbidden}

  defp reject_runtime(%module{} = value) when module not in [Date, Time, DateTime, NaiveDateTime],
    do: {:error, {:private_struct_forbidden, value.__struct__}}

  defp reject_runtime(value) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {_key, item}, :ok ->
      case reject_runtime(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reject_runtime(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn item, :ok ->
      case reject_runtime(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reject_runtime(_value), do: :ok

  defp reject_authority(value) when is_map(value) do
    leaked =
      value
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.filter(&(&1 in @authority_fields))

    if leaked == [] do
      Enum.reduce_while(value, :ok, fn {_key, item}, :ok ->
        case reject_authority(item) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      {:error, {:unknown_authority_field, Enum.sort(leaked)}}
    end
  end

  defp reject_authority(value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn item, :ok ->
      case reject_authority(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reject_authority(_value), do: :ok

  defp normalize_projection(projected) do
    projected
    |> Map.new(fn {key, value} -> {normalize_projection_key(key), normalize(value)} end)
    |> Map.update!(:event, &to_string/1)
  end

  defp normalize_projection_key(key) when is_binary(key), do: String.to_existing_atom(key)
  defp normalize_projection_key(key), do: key

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {normalize_key(key), normalize(item)} end)
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&normalize/1)
  defp normalize(value) when is_atom(value) and value not in [nil, true, false], do: Atom.to_string(value)
  defp normalize(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)

  defp bounded_limit(opts, key, maximum) do
    case Keyword.get(opts, key, maximum) do
      value when is_integer(value) and value > 0 -> min(value, maximum)
      _invalid -> maximum
    end
  end

  defp require_result_bound(encoded) when byte_size(encoded) <= 65_536, do: :ok
  defp require_result_bound(_encoded), do: {:error, :terminal_result_too_large}

  defp bounded_reason(reason) do
    if byte_size(inspect(reason, limit: 20, printable_limit: 4_096)) <= 4_096,
      do: reason,
      else: :projection_rejected
  end

  defp put_types(map, sources, type), do: Enum.reduce(sources, map, &Map.put(&2, &1, type))
end
