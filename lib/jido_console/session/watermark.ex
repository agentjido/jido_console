defmodule Jido.Console.Session.Watermark do
  @moduledoc """
  Verifies one durable boundary between Console history and Jidoka state.

  Each state is an immutable Console record. The verified record commits only
  after the module reads both committed stores and their operation receipts.
  A missing Console checkpoint projection can be rebuilt from the qualified
  Jidoka checkpoint identity. The rebuild path does not execute a provider or
  a tool.
  """

  alias Jido.Console.Session.Durable.{CanonicalJSON, JidokaValue, Record}
  alias Jido.Console.Session.{Event, Generation}
  alias Jido.Console.Session.Jidoka, as: SessionJidoka
  alias Jido.Console.Storage
  alias Jidoka.Session.Data, as: JidokaData
  alias Jidoka.Snapshot, as: JidokaSnapshot

  @console_only_tail_types ~w(input_admitted permission_decided command_effected control_completed)
  @storage_keys [:writer, :quota, :admission, :deadline]

  @type boundary :: %{String.t() => term()}

  @doc "Prepares one deterministic Console projection for a committed Jidoka checkpoint identity."
  @spec prepare_projection(String.t(), map(), Generation.t(), keyword()) ::
          {:ok, %{boundary: boundary(), event: map()}} | {:error, term()}
  def prepare_projection(watermark_id, jidoka_identity, fence, opts \\ [])
      when is_binary(watermark_id) and is_map(jidoka_identity) and is_list(opts) do
    with :ok <- Generation.validate(fence),
         {:ok, prior, sequence} <- next_console_position(fence.session_id, opts),
         event_id = projection_event_id(watermark_id),
         operation_id = "watermark-projection-#{watermark_id}",
         {:ok, event} <- projection_event(event_id, sequence, jidoka_identity, fence),
         {:ok, digest} <- preview_event_digest(event, fence.generation, sequence, prior) do
      console_identity = %{
        "session_id" => fence.session_id,
        "generation" => fence.generation,
        "sequence" => sequence,
        "event_id" => event_id,
        "operation_id" => operation_id,
        "chain_digest" => digest
      }

      boundary = %{
        "watermark_id" => watermark_id,
        "console_identity" => console_identity,
        "console_digest" => digest,
        "jidoka_identity" => jidoka_identity,
        "jidoka_digest" => jidoka_identity["value_digest"]
      }

      {:ok, %{boundary: boundary, event: event}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reserves one exact cross-store boundary before either side is accepted as verified."
  @spec reserve(boundary(), Generation.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reserve(boundary, fence, opts \\ []) when is_map(boundary) and is_list(opts) do
    with :ok <- Generation.validate(fence),
         :ok <- validate_boundary_fence(boundary, fence),
         {:ok, result} <- reserve_new_or_existing(boundary, fence, opts),
         :ok <- barrier(:after_reserved, opts) do
      {:ok, result}
    end
  end

  @doc "Verifies committed Jidoka and Console data, then commits the verified watermark last."
  @spec verify(String.t(), Generation.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(watermark_id, fence, opts \\ [])
      when is_binary(watermark_id) and is_list(opts) do
    with :ok <- Generation.validate(fence),
         :ok <- validate_live_fence(fence, opts),
         {:ok, history} <- Storage.watermark_history(watermark_id, storage_opts(opts)),
         {:ok, current} <- current_transition(history, watermark_id),
         :ok <- validate_boundary_fence(current.record["payload"], fence) do
      verify_current(current, fence, opts)
    end
  end

  @doc "Repairs only a missing Console checkpoint projection from recorded Jidoka identity data."
  @spec repair_projection(String.t(), Generation.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def repair_projection(watermark_id, fence, opts \\ [])
      when is_binary(watermark_id) and is_list(opts) do
    with {:ok, history} <- Storage.watermark_history(watermark_id, storage_opts(opts)),
         {:ok, current} <- current_transition(history, watermark_id),
         true <- current.state == "repair_required",
         payload = current.record["payload"],
         :ok <- validate_boundary_fence(payload, fence),
         {:ok, _jidoka} <- verify_jidoka(payload, fence, opts),
         {:error, {:canonical_event_not_found, _event_id}} <- verify_console(payload, opts),
         {:ok, event} <- projection_event_from_payload(payload, fence),
         :ok <- verify_projection_digest(event, payload, fence, opts),
         {:ok, projection} <-
           Storage.append_event(
             event,
             %{session_id: fence.session_id, sequence: get_in(payload, ["console_identity", "sequence"])},
             projection_storage_opts(payload, fence, opts)
           ),
         true <- projection.chain_digest == payload["console_digest"],
         :ok <- barrier(:after_projection_repair, opts) do
      verify(watermark_id, fence, opts)
    else
      false -> {:error, :watermark_projection_repair_not_available}
      {:ok, _existing} -> {:error, :watermark_console_projection_already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Appends an explicit terminal abandoned state without deleting evidence."
  @spec abandon(String.t(), Generation.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def abandon(watermark_id, fence, opts \\ []) when is_binary(watermark_id) and is_list(opts) do
    with {:ok, history} <- Storage.watermark_history(watermark_id, storage_opts(opts)),
         {:ok, current} <- current_transition(history, watermark_id),
         payload = current.record["payload"],
         :ok <- validate_boundary_fence(payload, fence) do
      append_state(payload, current, "abandoned", fence, opts)
    end
  end

  @doc "Returns the immutable history and exact-resume eligibility for one watermark."
  @spec inspect(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect(watermark_id, opts \\ []) when is_binary(watermark_id) and is_list(opts) do
    with {:ok, history} <- Storage.watermark_history(watermark_id, storage_opts(opts)),
         {:ok, current} <- current_transition(history, watermark_id) do
      {:ok,
       %{
         watermark_id: watermark_id,
         state: current.state,
         exact_resume: current.state == "verified",
         transitions: history
       }}
    end
  end

  defp verify_current(%{state: "verified"} = current, _fence, _opts) do
    {:ok, %{status: :verified, exact_resume: true, duplicate: true, transition: current}}
  end

  defp verify_current(%{state: "abandoned"}, _fence, _opts),
    do: {:error, :watermark_abandoned}

  defp verify_current(current, fence, opts) do
    payload = current.record["payload"]

    case verify_jidoka(payload, fence, opts) do
      {:ok, jidoka} -> verify_console_side(current, jidoka, fence, opts)
      {:error, reason} -> classify_one_sided(current, :jidoka, reason, fence, opts)
    end
  end

  defp verify_console_side(current, jidoka, fence, opts) do
    with {:ok, jidoka_transition} <- ensure_state(current, "jidoka_committed", fence, opts),
         :ok <- barrier(:after_jidoka_committed, opts) do
      case verify_console(jidoka_transition.record["payload"], opts) do
        {:ok, console} -> finish_verification(jidoka_transition, jidoka, console, fence, opts)
        {:error, reason} -> classify_one_sided(jidoka_transition, :console, reason, fence, opts)
      end
    end
  end

  defp finish_verification(current, jidoka, console, fence, opts) do
    with {:ok, console_transition} <- ensure_state(current, "console_committed", fence, opts),
         :ok <- barrier(:after_console_committed, opts) do
      case verify_tail(console_transition.record["payload"], opts) do
        :ok -> commit_verified(console_transition, jidoka, console, fence, opts)
        {:error, reason} -> classify_one_sided(console_transition, :console_tail, reason, fence, opts)
      end
    end
  end

  defp commit_verified(current, jidoka, console, fence, opts) do
    with {:ok, verified} <- ensure_state(current, "verified", fence, opts),
         :ok <- barrier(:after_verified, opts) do
      {:ok,
       %{
         status: :verified,
         exact_resume: true,
         duplicate: verified.duplicate,
         watermark: verified,
         console: console,
         jidoka: jidoka
       }}
    end
  end

  defp classify_one_sided(current, missing_side, reason, fence, opts) do
    action =
      case missing_side do
        :console -> :repair_console_projection
        :jidoka -> :transcript_only_or_abandon
        :console_tail -> :repair_or_transcript_only
      end

    with {:ok, transition} <- ensure_repair_required(current, fence, opts) do
      {:ok,
       %{
         status: :repair_required,
         exact_resume: false,
         missing_side: missing_side,
         reason: reason,
         action: action,
         watermark: transition
       }}
    end
  end

  defp ensure_repair_required(%{state: "repair_required"} = current, _fence, _opts),
    do: {:ok, current}

  defp ensure_repair_required(current, fence, opts),
    do: append_state(current.record["payload"], current, "repair_required", fence, opts)

  defp ensure_state(%{state: current_state} = current, state, fence, opts)
       when current_state != "repair_required" and
              current_state in ["jidoka_committed", "console_committed", "verified"] and
              state in ["jidoka_committed", "console_committed", "verified"] do
    if state_rank(current_state) >= state_rank(state) do
      {:ok, Map.put(current, :duplicate, true)}
    else
      append_state(current.record["payload"], current, state, fence, opts)
    end
  end

  defp ensure_state(current, state, fence, opts),
    do: append_state(current.record["payload"], current, state, fence, opts)

  defp state_rank("jidoka_committed"), do: 1
  defp state_rank("console_committed"), do: 2
  defp state_rank("verified"), do: 3

  defp verify_jidoka(payload, fence, opts) do
    identity = payload["jidoka_identity"]

    with {:ok, receipt} <- Storage.receipt(identity["operation_id"], storage_opts(opts)),
         :ok <- verify_receipt(receipt, "checkpoint", identity["session_id"], payload["jidoka_digest"]),
         {:ok, %JidokaData{} = session} <- Storage.jidoka_session(identity["session_id"], storage_opts(opts)),
         {:ok, encoded} <- JidokaValue.encode(session),
         true <- encoded.digest == payload["jidoka_digest"],
         true <- session.revision == identity["revision"],
         {:ok, %JidokaSnapshot{} = snapshot} <- find_snapshot(session, identity["snapshot_id"]),
         {:ok, mapping} <- watermark_mapping(payload),
         {:ok, checkpoint} <-
           SessionJidoka.checkpoint_identity(mapping, session, snapshot, console_fence: fence),
         :ok <- verify_checkpoint_identity(checkpoint, identity, fence) do
      {:ok, %{receipt: receipt, session: session, snapshot: snapshot, digest: encoded.digest}}
    else
      false -> {:error, :jidoka_watermark_identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_console(payload, opts) do
    identity = payload["console_identity"]

    with {:ok, event} <- Storage.canonical_event(identity["event_id"], storage_opts(opts)),
         {:ok, receipt} <- Storage.receipt(identity["operation_id"], storage_opts(opts)),
         :ok <- verify_receipt(receipt, "canonical_event", identity["event_id"], payload["console_digest"]),
         true <- event.session_id == identity["session_id"],
         true <- event.generation == identity["generation"],
         true <- event.sequence == identity["sequence"],
         true <- event.chain_digest == payload["console_digest"] do
      {:ok, %{receipt: receipt, event: event}}
    else
      false -> {:error, :console_watermark_identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_tail(payload, opts) do
    identity = payload["console_identity"]

    with {:ok, head} <- Storage.history_head(identity["session_id"], storage_opts(opts)),
         true <- head.sequence >= identity["sequence"],
         {:ok, tail} <-
           Storage.history_suffix(
             identity["session_id"],
             Keyword.merge(storage_opts(opts),
               after_sequence: identity["sequence"],
               limit: 1_000,
               max_bytes: 8 * 1_024 * 1_024
             )
           ),
         true <- tail_reaches_head?(tail, identity["sequence"], head.sequence),
         true <- Enum.all?(tail, &console_only_tail?/1) do
      :ok
    else
      false -> {:error, :watermark_execution_tail_present}
      {:error, reason} -> {:error, reason}
    end
  end

  defp console_only_tail?(%{event: %{"type" => type}}), do: type in @console_only_tail_types
  defp console_only_tail?(_record), do: false

  defp tail_reaches_head?([], boundary_sequence, head_sequence), do: boundary_sequence == head_sequence
  defp tail_reaches_head?(tail, _boundary_sequence, head_sequence), do: List.last(tail).sequence == head_sequence

  defp verify_receipt(receipt, kind, target_id, digest) do
    if receipt.kind == kind and receipt.target_id == target_id and receipt.result_digest == digest do
      :ok
    else
      {:error, {:watermark_receipt_mismatch, kind, target_id}}
    end
  end

  defp find_snapshot(%JidokaData{snapshots: snapshots}, snapshot_id) do
    case Enum.find(snapshots, &(&1.snapshot_id == snapshot_id)) do
      %JidokaSnapshot{} = snapshot -> {:ok, snapshot}
      nil -> {:error, {:jidoka_checkpoint_not_found, snapshot_id}}
    end
  end

  defp verify_checkpoint_identity(checkpoint, identity, fence) do
    expected = %{
      console_generation: fence.generation,
      console_session_id: fence.session_id,
      jidoka_session_id: identity["session_id"],
      jidoka_revision: identity["revision"],
      jidoka_request_id: identity["request_id"],
      jidoka_lease_id: identity["lease_id"],
      jidoka_snapshot_id: identity["snapshot_id"]
    }

    if Map.take(checkpoint, Map.keys(expected)) == expected,
      do: :ok,
      else: {:error, :jidoka_checkpoint_identity_mismatch}
  end

  defp append_state(boundary_or_payload, previous, state, fence, opts) do
    payload =
      boundary_or_payload
      |> Map.take(~w(watermark_id console_identity console_digest jidoka_identity jidoka_digest))
      |> Map.put("state", state)

    ordinal = if previous, do: previous.ordinal + 1, else: 0
    prior = if previous, do: previous.record_digest, else: "genesis"
    watermark_id = payload["watermark_id"]
    operation_id = "watermark-#{watermark_id}-#{ordinal}-#{state}"

    record =
      Record.new("verified_watermark", payload,
        record_id: "#{watermark_id}:#{ordinal}:#{state}",
        scope_id: "watermark:#{watermark_id}",
        generation: fence.generation,
        sequence: ordinal,
        prior_record_digest: prior
      )

    operation_fence = Generation.for_operation(fence, operation_id)

    with {:ok, result} <-
           Storage.append_watermark(
             record,
             opts
             |> storage_opts()
             |> Keyword.put(:operation_id, operation_id)
             |> Keyword.put(:fence, operation_fence)
           ),
         {:ok, history} <- Storage.watermark_history(watermark_id, storage_opts(opts)),
         {:ok, current} <- current_transition(history, watermark_id) do
      {:ok, Map.put(current, :duplicate, result.duplicate)}
    end
  end

  defp reserve_new_or_existing(boundary, fence, opts) do
    watermark_id = boundary["watermark_id"]

    case Storage.watermark_history(watermark_id, storage_opts(opts)) do
      {:ok, []} ->
        append_state(boundary, nil, "reserved", fence, opts)

      {:ok, [first | _rest]} ->
        expected = Map.take(boundary, ~w(watermark_id console_identity console_digest jidoka_identity jidoka_digest))
        actual = first.record["payload"] |> Map.delete("state")

        if actual == expected do
          {:ok, Map.put(first, :duplicate, true)}
        else
          {:error, {:watermark_reservation_conflict, watermark_id}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_transition([], watermark_id), do: {:error, {:watermark_not_found, watermark_id}}
  defp current_transition(history, _watermark_id), do: {:ok, List.last(history)}

  defp validate_boundary_fence(boundary, fence) do
    console = boundary["console_identity"] || %{}

    cond do
      console["session_id"] != fence.session_id -> {:error, :cross_session_watermark}
      console["generation"] != fence.generation -> {:error, :stale_watermark_generation}
      true -> :ok
    end
  end

  defp watermark_mapping(payload) do
    console_session_id = get_in(payload, ["console_identity", "session_id"])
    jidoka = payload["jidoka_identity"]

    kind =
      case jidoka["mapping_kind"] do
        "imported" -> :imported
        "forked" -> :forked
        _other -> :normal
      end

    SessionJidoka.session_mapping(console_session_id,
      jidoka_session_id: jidoka["session_id"],
      kind: kind
    )
  end

  defp validate_live_fence(fence, opts) do
    with {:ok, current} <- Storage.generation(fence.session_id, storage_opts(opts)),
         true <- current.state == :active,
         true <- current.generation == fence.generation,
         true <- current.owner_instance_id == fence.owner_instance_id do
      :ok
    else
      false -> {:error, :stale_watermark_generation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_console_position(session_id, opts) do
    case Storage.history_head(session_id, storage_opts(opts)) do
      {:ok, head} -> {:ok, head.chain_digest, head.sequence + 1}
      {:error, {:history_not_found, ^session_id}} -> {:ok, "genesis", 1}
      {:error, reason} -> {:error, reason}
    end
  end

  defp projection_event_from_payload(payload, fence) do
    console = payload["console_identity"]
    projection_event(console["event_id"], console["sequence"], payload["jidoka_identity"], fence)
  end

  defp projection_event(event_id, sequence, jidoka, fence) do
    Event.classify(%{
      "type" => "run_progress",
      "id" => event_id,
      "session_id" => fence.session_id,
      "sequence" => sequence,
      "durability" => "process",
      "sensitivity" => "public",
      "origin" => %{"kind" => "system", "actor_id" => "watermark-repair"},
      "trust" => %{"evidence" => jidoka["value_digest"], "policy" => "verified_jidoka_checkpoint"},
      "identities" => [
        %{
          "kind" => "session",
          "id" => fence.session_id,
          "session_id" => fence.session_id,
          "generation" => fence.generation,
          "owner_instance_id" => fence.owner_instance_id
        },
        %{
          "kind" => "jidoka_checkpoint",
          "id" => jidoka["snapshot_id"],
          "session_id" => fence.session_id
        }
      ],
      "run_id" => jidoka["request_id"],
      "summary" => %{
        "event" => "jidoka_checkpoint_projected",
        "jidoka_revision" => jidoka["revision"],
        "snapshot_id" => jidoka["snapshot_id"]
      }
    })
  end

  defp verify_projection_digest(event, payload, fence, opts) do
    console = payload["console_identity"]

    with {:ok, prior, sequence} <- next_console_position(fence.session_id, opts),
         true <- sequence == console["sequence"],
         {:ok, digest} <- preview_event_digest(event, fence.generation, sequence, prior),
         true <- digest == payload["console_digest"] do
      :ok
    else
      false -> {:error, :watermark_projection_drift}
      {:error, reason} -> {:error, reason}
    end
  end

  defp preview_event_digest(event, generation, sequence, prior) do
    payload = event["payload"]

    with {:ok, origin} <- CanonicalJSON.encode(payload["origin"]),
         {:ok, trust} <- CanonicalJSON.encode(payload["trust"]),
         record =
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
           ),
         {:ok, encoded} <- Record.encode(record) do
      {:ok, encoded.digest}
    end
  end

  defp projection_event_id(watermark_id), do: "watermark-projection-#{watermark_id}"

  defp projection_storage_opts(payload, fence, opts) do
    operation_id = get_in(payload, ["console_identity", "operation_id"])

    opts
    |> storage_opts()
    |> Keyword.put(:operation_id, operation_id)
    |> Keyword.put(:fence, Generation.for_operation(fence, operation_id))
  end

  defp storage_opts(opts), do: Keyword.take(opts, @storage_keys)

  defp barrier(boundary, opts) do
    case Keyword.get(opts, :crash_at) do
      ^boundary -> {:error, {:injected_watermark_crash, boundary}}
      _other -> :ok
    end
  end
end
