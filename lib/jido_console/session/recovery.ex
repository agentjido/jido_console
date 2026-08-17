defmodule Jido.Console.Session.Recovery do
  @moduledoc """
  Bounded process-lifetime attach and delivery-gap recovery.

  Recovery uses one canonical snapshot, one contiguous event suffix, and one
  exact completion token. It is not application-restart recovery, durable
  resume, or a durable delivery receipt.
  """

  alias Jido.Console.Session.{Delivery, Protocol, Reducer, State}
  alias Jido.Console.Session.Protocol.Validator

  @max_snapshot_bytes 1_048_576
  @max_suffix_count 1_000
  @max_suffix_bytes 1_048_576
  @snapshot_keys ~w(session_id sequence history queues active_run)

  @doc "Builds the one bounded canonical snapshot returned by attach."
  @spec attach_snapshot(State.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def attach_snapshot(state, identity, opts \\ []) do
    attrs =
      identity_attrs(identity)
      |> Map.merge(%{
        "id" => "attach_#{get(identity, :attachment_id)}",
        "snapshot_sequence" => state.sequence,
        "snapshot" => State.to_snapshot_protocol(state)
      })

    with :ok <- State.validate(state),
         :ok <- validate_identity(state, identity),
         {:ok, envelope} <- envelope("attach_snapshot", attrs),
         :ok <- enforce_size(envelope, limit(opts, :snapshot_bytes, @max_snapshot_bytes), :snapshot_limit_exceeded) do
      {:ok, envelope}
    end
  end

  @doc "Begins recovery for the exact current gap."
  @spec begin(State.t(), Delivery.t(), map(), String.t(), keyword()) ::
          {:ok, Delivery.t(), map()} | {:error, term(), Delivery.t()}
  def begin(state, delivery, identity, gap_id, opts \\ []) do
    with :ok <- State.validate(state),
         :ok <- validate_identity(state, identity),
         :ok <- validate_delivery_identity(delivery, identity),
         :ok <- require_gap(delivery, gap_id) do
      recovery_id = "rec_#{delivery.next_gap}_#{state.sequence}"
      recovery_token = token(delivery, "recover", [gap_id, recovery_id, state.sequence])

      attrs =
        identity_attrs(identity)
        |> Map.merge(%{
          "id" => recovery_id,
          "gap_id" => gap_id,
          "recovery_id" => recovery_id,
          "snapshot_sequence" => state.sequence,
          "recovery_token" => recovery_token,
          "snapshot" => State.to_snapshot_protocol(state)
        })

      with {:ok, snapshot} <- envelope("recovery_snapshot", attrs),
           :ok <-
             enforce_size(
               snapshot,
               limit(opts, :snapshot_bytes, @max_snapshot_bytes),
               :snapshot_limit_exceeded
             ) do
        recovery = %{
          gap_id: gap_id,
          recovery_id: recovery_id,
          recovery_token: recovery_token,
          snapshot_sequence: state.sequence,
          completion_token: nil,
          through_sequence: nil
        }

        delivery = %{
          delivery
          | status: :recovering,
            recovery: recovery,
            advisory_outstanding: false,
            inflight: nil
        }

        {:ok, delivery, snapshot}
      else
        {:error, reason} -> {:error, reason, delivery}
      end
    else
      {:error, reason} -> {:error, reason, delivery}
    end
  end

  @doc "Selects one bounded contiguous suffix for an active recovery."
  @spec replay(State.t(), Delivery.t(), map(), String.t(), keyword()) ::
          {:ok, Delivery.t(), map()} | {:error, term(), Delivery.t()}
  def replay(state, delivery, identity, recovery_token, opts \\ []) do
    with :ok <- validate_identity(state, identity),
         :ok <- validate_delivery_identity(delivery, identity),
         {:ok, recovery} <- require_recovery(delivery, recovery_token),
         :ok <- require_suffix_not_issued(recovery),
         {:ok, events} <- select_suffix(state, recovery.snapshot_sequence, opts),
         through = suffix_through(events, recovery.snapshot_sequence),
         completion_token =
           token(delivery, "complete", [recovery.gap_id, recovery.recovery_id, through]),
         attrs =
           identity_attrs(identity)
           |> Map.merge(%{
             "id" => "suffix_#{recovery.recovery_id}",
             "gap_id" => recovery.gap_id,
             "recovery_id" => recovery.recovery_id,
             "after_sequence" => recovery.snapshot_sequence,
             "through_sequence" => through,
             "recovery_token" => recovery.recovery_token,
             "completion_token" => completion_token,
             "events" => events
           }),
         {:ok, suffix} <- envelope("recovery_suffix", attrs),
         :ok <- enforce_size(suffix, limit(opts, :suffix_bytes, @max_suffix_bytes), :recovery_window_exceeded) do
      recovery = %{
        recovery
        | completion_token: completion_token,
          through_sequence: through
      }

      {:ok, %{delivery | recovery: recovery}, suffix}
    else
      {:error, reason} -> {:error, reason, delivery}
    end
  end

  @doc "Completes recovery after the exact suffix was applied."
  @spec complete(Delivery.t(), map(), String.t()) ::
          {:ok, Delivery.t(), map(), boolean()} | {:error, term(), Delivery.t()}
  def complete(delivery, identity, completion_token) do
    with :ok <- validate_delivery_identity(delivery, identity),
         {:ok, recovery} <- require_completion(delivery, completion_token) do
      remaining =
        Enum.reject(delivery.queue, fn event ->
          event_sequence(event) <= recovery.through_sequence
        end)

      advisory? = remaining != []

      attrs =
        identity_attrs(identity)
        |> Map.merge(%{
          "id" => "receipt_#{recovery.recovery_id}",
          "recovery_id" => recovery.recovery_id,
          "through_sequence" => recovery.through_sequence,
          "process_lifetime" => true
        })

      case envelope("recovery_receipt", attrs) do
        {:ok, receipt} ->
          delivery = %{
            delivery
            | status: :open,
              queue: remaining,
              queued_bytes: Delivery.queue_bytes(remaining),
              advisory_outstanding: advisory?,
              last_acked: recovery.through_sequence,
              last_ack: nil,
              gap: nil,
              recovery: nil,
              inflight: nil
          }

          {:ok, delivery, receipt, advisory?}

        {:error, reason} ->
          {:error, reason, delivery}
      end
    else
      {:error, reason} -> {:error, reason, delivery}
    end
  end

  @doc "Restores canonical state from a validated attach or recovery snapshot."
  @spec restore_snapshot(map(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def restore_snapshot(envelope, opts \\ []) do
    with {:ok, envelope} <- Validator.validate(envelope),
         true <- envelope["family"] == "delivery" and envelope["type"] in ~w(attach_snapshot recovery_snapshot),
         :ok <- enforce_size(envelope, limit(opts, :snapshot_bytes, @max_snapshot_bytes), :snapshot_limit_exceeded),
         snapshot when is_map(snapshot) <- get_in(envelope, ["payload", "snapshot"]),
         true <- envelope["session_id"] == snapshot["session_id"],
         :ok <- validate_snapshot_shape(snapshot),
         {:ok, restored} <- restore_canonical(snapshot) do
      {:ok, restored}
    else
      false -> {:error, :invalid_recovery_snapshot}
      nil -> {:error, :invalid_recovery_snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Applies a validated suffix to temporary projection state."
  @spec apply_suffix(State.t(), map(), map(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def apply_suffix(state, suffix, identity, opts \\ []) do
    with {:ok, suffix} <- Validator.validate(suffix),
         true <- suffix["family"] == "delivery" and suffix["type"] == "recovery_suffix",
         :ok <- validate_identity(state, identity),
         :ok <- validate_envelope_identity(suffix, identity),
         :ok <- enforce_size(suffix, limit(opts, :suffix_bytes, @max_suffix_bytes), :recovery_window_exceeded),
         payload = suffix["payload"],
         true <- payload["after_sequence"] == state.sequence,
         events when is_list(events) <- payload["events"],
         :ok <- validate_suffix(events, payload["after_sequence"], payload["through_sequence"]),
         {:ok, restored} <- Reducer.replay(events, state),
         true <- restored.sequence == payload["through_sequence"] do
      {:ok, restored}
    else
      false -> {:error, :invalid_recovery_sequence}
      nil -> {:error, :invalid_recovery_suffix}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the Milestone 3 durability boundary."
  @spec limitation() :: String.t()
  def limitation,
    do:
      "Recovery is process-lifetime only; it is not application-restart recovery, durable resume, or a durable receipt."

  defp restore_canonical(snapshot) do
    session_id = snapshot["session_id"]
    history = snapshot["history"]

    with true <- is_binary(session_id) and is_list(history),
         {:ok, restored} <- Reducer.replay(history, State.new(session_id)),
         true <- restored.sequence == snapshot["sequence"],
         true <- queues_protocol(restored) == snapshot["queues"],
         true <- restored.active_run == snapshot["active_run"],
         :ok <- State.validate(restored) do
      {:ok, restored}
    else
      false -> {:error, :invalid_recovery_snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_suffix(state, after_sequence, opts) do
    count_limit = limit(opts, :suffix_count, @max_suffix_count)
    events = Enum.filter(state.history, &(event_sequence(&1) > after_sequence))

    cond do
      length(events) > count_limit ->
        {:error, :recovery_window_exceeded}

      validate_suffix(events, after_sequence, suffix_through(events, after_sequence)) != :ok ->
        {:error, :invalid_recovery_sequence}

      true ->
        {:ok, events}
    end
  end

  defp validate_suffix(events, after_sequence, through_sequence) do
    expected = Enum.to_list((after_sequence + 1)..through_sequence//1)
    actual = Enum.map(events, &event_sequence/1)

    cond do
      events == [] and through_sequence == after_sequence -> :ok
      actual == expected -> :ok
      true -> {:error, :invalid_recovery_sequence}
    end
  end

  defp require_gap(%{status: :gapped, gap: %{"payload" => %{"gap_id" => gap_id}}}, gap_id),
    do: :ok

  defp require_gap(%{status: :gapped}, _gap_id), do: {:error, :stale_gap_identity}
  defp require_gap(_delivery, _gap_id), do: {:error, :recovery_not_required}

  defp require_recovery(%{status: :recovering, recovery: recovery}, token)
       when not is_nil(recovery) do
    if recovery.recovery_token == token,
      do: {:ok, recovery},
      else: {:error, :stale_recovery_token}
  end

  defp require_recovery(_delivery, _token), do: {:error, :stale_recovery_token}

  defp require_suffix_not_issued(%{completion_token: nil}), do: :ok
  defp require_suffix_not_issued(_recovery), do: {:error, :recovery_suffix_already_issued}

  defp require_completion(%{status: :recovering, recovery: recovery}, token)
       when not is_nil(recovery) do
    cond do
      is_nil(recovery.completion_token) -> {:error, :recovery_suffix_required}
      recovery.completion_token != token -> {:error, :stale_completion_token}
      true -> {:ok, recovery}
    end
  end

  defp require_completion(_delivery, _token), do: {:error, :stale_completion_token}

  defp validate_identity(state, identity) do
    if get(identity, :session_id) == state.session_id,
      do: :ok,
      else: {:error, :recovery_identity_mismatch}
  end

  defp validate_delivery_identity(delivery, identity) do
    cond do
      get(identity, :session_id) != delivery.session_id -> {:error, :recovery_identity_mismatch}
      get(identity, :client_id) != delivery.client_id -> {:error, :recovery_identity_mismatch}
      get(identity, :attachment_id) != delivery.attachment_id -> {:error, :recovery_identity_mismatch}
      true -> :ok
    end
  end

  defp validate_envelope_identity(envelope, identity) do
    payload = envelope["payload"] || %{}

    cond do
      envelope["session_id"] != get(identity, :session_id) -> {:error, :recovery_identity_mismatch}
      payload["client_id"] != get(identity, :client_id) -> {:error, :recovery_identity_mismatch}
      payload["attachment_id"] != get(identity, :attachment_id) -> {:error, :recovery_identity_mismatch}
      true -> :ok
    end
  end

  defp validate_snapshot_shape(snapshot) do
    cond do
      Map.keys(snapshot) |> Enum.sort() != Enum.sort(@snapshot_keys) ->
        {:error, :invalid_recovery_snapshot}

      not is_integer(snapshot["sequence"]) or snapshot["sequence"] < 0 ->
        {:error, :invalid_recovery_snapshot}

      true ->
        State.validate(snapshot)
    end
  end

  defp envelope(type, attrs) do
    with {:ok, schema} <- Protocol.schema(),
         {:ok, envelope} <- Protocol.envelope(schema, "delivery", type, attrs) do
      Validator.validate(envelope)
    end
  end

  defp enforce_size(value, maximum, reason) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= maximum -> :ok
      {:ok, _encoded} -> {:error, reason}
      {:error, _reason} -> {:error, :nonportable_recovery_value}
    end
  end

  defp token(delivery, purpose, parts) do
    data =
      [purpose, delivery.session_id, delivery.client_id, delivery.attachment_id | Enum.map(parts, &to_string/1)]
      |> Enum.join(<<0>>)

    digest = :crypto.mac(:hmac, :sha256, delivery.secret, data)
    purpose <> "_" <> Base.url_encode64(digest, padding: false)
  end

  defp identity_attrs(identity) do
    %{
      "session_id" => get(identity, :session_id),
      "client_id" => get(identity, :client_id),
      "attachment_id" => get(identity, :attachment_id)
    }
  end

  defp queues_protocol(state) do
    %{"steering" => state.queues.steering, "follow_up" => state.queues.follow_up}
  end

  defp suffix_through([], after_sequence), do: after_sequence
  defp suffix_through(events, _after_sequence), do: event_sequence(List.last(events))
  defp event_sequence(event), do: get_in(event, ["payload", "sequence"]) || 0

  defp limit(opts, key, maximum) do
    case Keyword.get(opts, key, maximum) do
      value when is_integer(value) and value > 0 -> min(value, maximum)
      _invalid -> maximum
    end
  end

  defp get(map, key) when is_map(map), do: map[key] || map[Atom.to_string(key)]
  defp get(_map, _key), do: nil
end
