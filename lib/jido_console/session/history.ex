defmodule Jido.Console.Session.History do
  @moduledoc "Durable canonical event history and bounded semantic rebuild."

  alias Jido.Console.Digest
  alias Jido.Console.Session.{Durable.SemanticSnapshot, Event, Generation, Reducer, State}
  alias Jido.Console.Storage

  @snapshot_events 500
  @snapshot_suffix_bytes 8 * 1_024 * 1_024
  @suffix_events 1_000
  @suffix_bytes 8 * 1_024 * 1_024
  @boundary_types ~w(run_completed run_failed session_failed permission_requested)

  @doc "Durably appends one reduced event before live client delivery."
  @spec append(map(), State.t(), Generation.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def append(event, semantic, fence, opts \\ []) do
    with {:ok, event} <- Event.validate(event),
         :ok <- validate_semantic(event, semantic, fence),
         operation_id = operation_id("event", event["id"]),
         event_fence = Generation.for_operation(fence, operation_id),
         {:ok, result} <-
           Storage.append_event(event, semantic, storage_opts(opts, operation_id, event_fence)) do
      maybe_snapshot(result, event, semantic, fence, opts)
    end
  end

  @doc "Persists one explicit derived snapshot at a safe boundary."
  @spec snapshot(State.t(), Generation.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(state, fence, reason, opts \\ []) do
    with {:ok, head} <- Storage.history_head(state.session_id, opts),
         true <- head.sequence == state.sequence,
         snapshot_id = snapshot_id(state.session_id, state.sequence, head.chain_digest, reason),
         {:ok, encoded} <- SemanticSnapshot.encode(snapshot_id, state, head, reason),
         operation_id = operation_id("snapshot", snapshot_id),
         snapshot_fence = Generation.for_operation(fence, operation_id),
         {:ok, result} <-
           Storage.put_semantic_snapshot(encoded, storage_opts(opts, operation_id, snapshot_fence)) do
      {:ok, result}
    else
      false -> {:error, :semantic_snapshot_head_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Rebuilds semantic state from a verified snapshot and one bounded event suffix."
  @spec rebuild(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rebuild(session_id, opts \\ []) when is_binary(session_id) do
    case Storage.history_head(session_id, opts) do
      {:ok, head} ->
        rebuild_from_candidates(session_id, head, opts)

      {:error, {:history_not_found, ^session_id}} ->
        {:ok,
         %{
           state: State.new(session_id),
           snapshot: nil,
           suffix_events: 0,
           suffix_bytes: 0,
           rebuild_time_us: 0
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Returns the snapshot and suffix limits used by durable rebuild."
  @spec limits() :: map()
  def limits do
    %{
      snapshot_events: @snapshot_events,
      snapshot_suffix_bytes: @snapshot_suffix_bytes,
      snapshot_bytes: SemanticSnapshot.max_bytes(),
      suffix_events: @suffix_events,
      suffix_bytes: @suffix_bytes
    }
  end

  defp maybe_snapshot(%{duplicate: true} = result, _event, _state, _fence, _opts),
    do: {:ok, Map.put(result, :snapshot, :not_due)}

  defp maybe_snapshot(result, event, state, fence, opts) do
    reason = snapshot_reason(result, event)

    case reason do
      nil ->
        {:ok, Map.put(result, :snapshot, :not_due)}

      reason ->
        case snapshot(state, fence, reason, opts) do
          {:ok, snapshot} -> {:ok, Map.put(result, :snapshot, snapshot)}
          {:error, snapshot_reason} -> {:ok, Map.put(result, :snapshot, {:error, snapshot_reason})}
        end
    end
  end

  defp snapshot_reason(
         _result,
         %{"type" => "run_progress", "payload" => %{"summary" => %{"event" => "turn_hibernated"}}}
       ),
       do: "hibernation"

  defp snapshot_reason(_result, %{"type" => type}) when type in @boundary_types do
    if type == "permission_requested", do: "approval_wait", else: "terminal"
  end

  defp snapshot_reason(%{suffix_events: count}, _event) when count >= @snapshot_events, do: "interval"

  defp snapshot_reason(%{suffix_bytes: bytes}, _event) when bytes >= @snapshot_suffix_bytes,
    do: "suffix_bytes"

  defp snapshot_reason(_result, _event), do: nil

  defp rebuild_from_candidates(session_id, head, opts) do
    started = System.monotonic_time(:microsecond)

    with {:ok, candidates} <- Storage.semantic_snapshots(session_id, opts),
         {:ok, base, selected} <- select_snapshot(candidates, session_id, head.sequence),
         {:ok, records} <-
           Storage.history_suffix(
             session_id,
             Keyword.merge(opts,
               after_sequence: base.sequence,
               limit: @suffix_events,
               max_bytes: @suffix_bytes
             )
           ),
         :ok <- verify_chain(records, selected, head),
         events = Enum.map(records, & &1.event),
         {:ok, state} <- Reducer.replay(events, base),
         true <- state.sequence == head.sequence do
      {:ok,
       %{
         state: state,
         snapshot: selected && selected.snapshot_id,
         suffix_events: length(records),
         suffix_bytes: Enum.sum(Enum.map(records, & &1.encoded_bytes)),
         rebuild_time_us: System.monotonic_time(:microsecond) - started,
         chain_digest: head.chain_digest
       }}
    else
      false -> {:error, :snapshot_rebuild_required}
      {:error, :history_suffix_limit} -> {:error, :snapshot_rebuild_required}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_snapshot(candidates, session_id, head_sequence) do
    Enum.reduce_while(candidates, {:ok, State.new(session_id), nil}, fn candidate, fallback ->
      case SemanticSnapshot.decode(candidate.bytes, candidate.digest) do
        {:ok, encoded} ->
          with true <- encoded.value["session_id"] == session_id,
               true <- encoded.value["source_sequence"] <= head_sequence,
               true <- encoded.value["source_sequence"] == candidate.source_sequence,
               true <- encoded.value["source_chain_digest"] == candidate.source_chain_digest,
               {:ok, state} <- SemanticSnapshot.restore(encoded) do
            {:halt, {:ok, state, Map.put(candidate, :encoded, encoded)}}
          else
            _invalid -> {:cont, fallback}
          end

        {:error, _reason} ->
          {:cont, fallback}
      end
    end)
  end

  defp verify_chain(records, selected, head) do
    prior = if selected, do: selected.source_chain_digest, else: "genesis"

    records
    |> Enum.reduce_while({:ok, prior}, fn record, {:ok, expected} ->
      cond do
        record.prior_digest != expected -> {:halt, {:error, :canonical_history_chain_mismatch}}
        record.record_digest != record.encoded.digest -> {:halt, {:error, :canonical_history_digest_mismatch}}
        true -> {:cont, {:ok, record.record_digest}}
      end
    end)
    |> case do
      {:ok, digest} when digest == head.chain_digest -> :ok
      {:ok, _digest} -> {:error, :canonical_history_head_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_semantic(event, semantic, fence) do
    cond do
      semantic.session_id != fence.session_id or event["session_id"] != fence.session_id ->
        {:error, :cross_session_history}

      semantic.sequence != get_in(event, ["payload", "sequence"]) ->
        {:error, :semantic_history_sequence_mismatch}

      true ->
        with :ok <- validate_event_generation(event, fence), do: State.validate(semantic)
    end
  end

  defp validate_event_generation(event, fence) do
    identities = get_in(event, ["payload", "identities"]) || []

    case Enum.filter(identities, &(&1["kind"] == "session")) do
      [
        %{
          "id" => session_id,
          "generation" => generation,
          "owner_instance_id" => owner_instance_id
        }
      ]
      when session_id == fence.session_id and generation == fence.generation and
             owner_instance_id == fence.owner_instance_id ->
        :ok

      _other ->
        {:error, :event_generation_mismatch}
    end
  end

  defp storage_opts(opts, operation_id, fence) do
    opts
    |> Keyword.take([:writer, :quota, :admission, :deadline])
    |> Keyword.put(:operation_id, operation_id)
    |> Keyword.put(:fence, fence)
  end

  defp snapshot_id(session_id, sequence, digest, reason),
    do: "snap-" <> short_digest([session_id, Integer.to_string(sequence), digest, reason])

  defp operation_id(kind, identity), do: "history-#{kind}-" <> short_digest([identity])

  defp short_digest(values) do
    values
    |> Enum.join("\0")
    |> Digest.portable()
    |> String.replace_prefix("sha256:", "")
  end
end
