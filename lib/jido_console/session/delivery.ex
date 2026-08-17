defmodule Jido.Console.Session.Delivery do
  @moduledoc """
  Bounded process-lifetime delivery for one exact client attachment.

  The receiver gets one small readiness advisory. It pulls one bounded batch
  and must acknowledge the exact opaque token before it can pull again.
  Delivery state and receipts are not durable across an application restart.
  """

  alias Jido.Console.Session.{Event, Protocol}
  alias Jido.Console.Session.Protocol.Validator

  @maximums %{
    advisory_count: 1,
    queue_count: 32,
    queue_bytes: 1_048_576,
    batch_count: 16,
    batch_bytes: 262_144,
    advisory_bytes: 4_096,
    ack_timeout_ms: 5_000,
    copied_bytes: 262_144
  }

  @type status :: :open | :ack_required | :gapped | :recovering | :detached

  @type t :: %{
          status: status(),
          session_id: String.t(),
          client_id: String.t(),
          attachment_id: String.t(),
          queue: [map()],
          queued_bytes: non_neg_integer(),
          advisory_outstanding: boolean(),
          last_acked: non_neg_integer(),
          last_ack: map() | nil,
          inflight: map() | nil,
          gap: map() | nil,
          limits: map(),
          secret: binary(),
          next_batch: pos_integer(),
          next_gap: pos_integer()
        }

  @doc "Returns the fixed protocol maximums."
  @spec maximums() :: map()
  def maximums, do: @maximums

  @doc "Starts delivery for one exact attachment at a snapshot baseline."
  @spec new(keyword()) :: t()
  def new(opts) do
    limits = lower_limits(Keyword.get(opts, :limits, %{}))
    session_id = Keyword.fetch!(opts, :session_id)
    client_id = Keyword.fetch!(opts, :client_id)
    attachment_id = Keyword.fetch!(opts, :attachment_id)

    %{
      status: :open,
      session_id: session_id,
      client_id: client_id,
      attachment_id: attachment_id,
      queue: [],
      queued_bytes: 0,
      advisory_outstanding: false,
      last_acked: Keyword.get(opts, :baseline, 0),
      last_ack: nil,
      inflight: nil,
      gap: nil,
      limits: limits,
      secret: Keyword.get_lazy(opts, :token_secret, fn -> :crypto.strong_rand_bytes(32) end),
      next_batch: 1,
      next_gap: 1
    }
  end

  @doc "Returns the small receiver advisory."
  @spec advisory(t()) :: tuple()
  def advisory(state),
    do: {:jido_console_session, state.attachment_id, :output_ready}

  @doc "Offers one canonical event without copying it to the receiver."
  @spec offer(t(), map()) ::
          {:ok, t(), boolean()} | {:duplicate, t()} | {:gap, t(), map(), boolean()}
  def offer(%{status: :detached} = state, _event), do: {:gap, state, nil, false}
  def offer(%{status: :gapped} = state, _event), do: {:gap, state, state.gap, false}

  def offer(state, event) when state.status in [:open, :ack_required, :recovering] do
    with {:ok, event} <- Event.validate(event),
         :ok <- require_session(state, event),
         {:ok, encoded_size} <- encoded_size(event) do
      cond do
        duplicate?(state, event) ->
          {:duplicate, state}

        encoded_size > state.limits.batch_bytes or encoded_size > state.limits.queue_bytes ->
          make_gap(state, event_sequence(event), "update_too_large")

        length(state.queue) >= state.limits.queue_count ->
          make_gap(state, event_sequence(event), "queue_count_overflow")

        state.queued_bytes + encoded_size > state.limits.queue_bytes ->
          make_gap(state, event_sequence(event), "queue_byte_overflow")

        true ->
          queue = state.queue ++ [event]
          state = %{state | queue: queue, queued_bytes: state.queued_bytes + encoded_size}
          maybe_advise(state)
      end
    else
      {:error, reason} -> make_gap(state, event_sequence(event), bounded_reason(reason))
    end
  end

  @doc "Pulls one bounded output batch or the current gap."
  @spec pull(t(), map()) ::
          {:ok, t(), map()}
          | {:gap, t(), map()}
          | {:empty, t()}
          | {:error, term(), t()}
  def pull(state, identity) do
    case require_identity(state, identity) do
      :ok -> do_pull(%{state | advisory_outstanding: false})
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp do_pull(%{status: :gapped} = state), do: {:gap, state, state.gap}
  defp do_pull(%{status: :recovering} = state), do: {:error, :delivery_recovering, state}
  defp do_pull(%{status: :ack_required} = state), do: {:error, :ack_required, state}
  defp do_pull(%{status: :detached} = state), do: {:error, :attachment_detached, state}
  defp do_pull(%{queue: []} = state), do: {:empty, state}

  defp do_pull(state) do
    {events, remaining} = select_batch(state, state.queue)

    case build_batch(state, events) do
      {:ok, batch, meta} ->
        queued_bytes = encoded_events_size(remaining)

        state = %{
          state
          | status: :ack_required,
            queue: remaining,
            queued_bytes: queued_bytes,
            inflight: meta,
            next_batch: state.next_batch + 1
        }

        {:ok, state, batch}

      {:error, reason} ->
        make_gap(state, event_sequence(hd(events)), bounded_reason(reason))
        |> then(fn {:gap, gapped, gap, _advisory?} -> {:gap, gapped, gap} end)
    end
  end

  @doc "Acknowledges the exact in-flight batch token."
  @spec ack(t(), map(), String.t()) ::
          {:ok, t(), map(), boolean()} | {:error, term(), t()}
  def ack(state, identity, token) when is_binary(token) do
    case require_identity(state, identity) do
      :ok -> do_ack(state, token)
      {:error, reason} -> {:error, reason, state}
    end
  end

  def ack(state, _identity, _token), do: {:error, :invalid_acknowledgement, state}

  defp do_ack(%{status: :gapped} = state, _token), do: {:error, :delivery_gapped, state}
  defp do_ack(%{status: :recovering} = state, _token), do: {:error, :delivery_recovering, state}
  defp do_ack(%{status: :detached} = state, _token), do: {:error, :attachment_detached, state}

  defp do_ack(%{inflight: nil, last_ack: %{token: token, receipt: receipt}} = state, token),
    do: {:ok, state, receipt, false}

  defp do_ack(%{inflight: nil} = state, _token),
    do: {:error, :invalid_acknowledgement, state}

  defp do_ack(%{inflight: %{token: token} = inflight} = state, token) do
    receipt = %{
      "session_id" => state.session_id,
      "client_id" => state.client_id,
      "attachment_id" => state.attachment_id,
      "batch_id" => inflight.batch_id,
      "through_sequence" => inflight.through_sequence,
      "process_lifetime" => true
    }

    state = %{
      state
      | status: :open,
        inflight: nil,
        last_acked: inflight.through_sequence,
        last_ack: %{token: token, receipt: receipt}
    }

    case maybe_advise(state) do
      {:ok, state, advisory?} -> {:ok, state, receipt, advisory?}
    end
  end

  defp do_ack(state, _token), do: {:error, :invalid_acknowledgement, state}

  @doc "Changes an exact timed-out batch into one bounded gap."
  @spec timeout(t(), String.t(), String.t(), non_neg_integer()) ::
          {:gap, t(), map(), boolean()} | {:ok, t()}
  def timeout(state, attachment_id, timer_token, current_sequence) do
    case state do
      %{
        status: :ack_required,
        attachment_id: ^attachment_id,
        inflight: %{timer_token: ^timer_token}
      } ->
        make_gap(state, current_sequence, "acknowledgement_timeout")

      _other ->
        {:ok, state}
    end
  end

  @doc "Clears copied data and marks this exact attachment detached."
  @spec detach(t()) :: t()
  def detach(state) do
    %{
      state
      | status: :detached,
        queue: [],
        queued_bytes: 0,
        inflight: nil,
        advisory_outstanding: false,
        gap: nil
    }
  end

  @doc "Supports only the temporary legacy TUI acknowledgement route."
  @spec legacy_ack(t(), non_neg_integer(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def legacy_ack(state, sequence, owner_sequence)
      when is_integer(sequence) and sequence >= state.last_acked and sequence <= owner_sequence do
    {:ok, %{state | last_acked: sequence}}
  end

  def legacy_ack(state, sequence, _owner_sequence) when sequence < state.last_acked,
    do: {:error, :stale_ack}

  def legacy_ack(_state, _sequence, _owner_sequence), do: {:error, :future_ack}

  @doc "Returns copied and queued payload measurements."
  @spec measurements(t()) :: map()
  def measurements(state) do
    %{
      status: state.status,
      queue_count: length(state.queue),
      queued_bytes: state.queued_bytes,
      inflight_bytes: if(state.inflight, do: state.inflight.bytes, else: 0),
      advisory_count: if(state.advisory_outstanding, do: 1, else: 0)
    }
  end

  defp build_batch(state, events) do
    batch_id = "bat_#{state.next_batch}"
    first = event_sequence(hd(events))
    through = event_sequence(List.last(events))
    token = token(state, "ack", [batch_id, first, through])
    timer_token = token(state, "timer", [batch_id, through])

    attrs = %{
      "id" => batch_id,
      "session_id" => state.session_id,
      "client_id" => state.client_id,
      "attachment_id" => state.attachment_id,
      "batch_id" => batch_id,
      "first_sequence" => first,
      "through_sequence" => through,
      "acknowledgement_token" => token,
      "events" => events
    }

    with {:ok, schema} <- Protocol.schema(),
         {:ok, batch} <- Protocol.envelope(schema, "delivery", "output_batch", attrs),
         {:ok, batch} <- Validator.validate(batch),
         {:ok, bytes} <- encoded_size(batch),
         true <- bytes <= state.limits.batch_bytes and bytes <= state.limits.copied_bytes do
      {:ok, batch,
       %{
         batch_id: batch_id,
         first_sequence: first,
         through_sequence: through,
         token: token,
         timer_token: timer_token,
         bytes: bytes,
         count: length(events)
       }}
    else
      false -> {:error, :batch_limit_exceeded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp make_gap(state, current_sequence, reason) do
    gap_id = "gap_#{state.next_gap}"

    attrs = %{
      "id" => gap_id,
      "session_id" => state.session_id,
      "client_id" => state.client_id,
      "attachment_id" => state.attachment_id,
      "gap_id" => gap_id,
      "last_acknowledged_sequence" => state.last_acked,
      "current_owner_sequence" => max(current_sequence, state.last_acked),
      "reason" => String.slice(to_string(reason), 0, 256)
    }

    {:ok, schema} = Protocol.schema()
    {:ok, gap} = Protocol.envelope(schema, "delivery", "gap", attrs)
    {:ok, gap} = Validator.validate(gap)

    advisory? = not state.advisory_outstanding

    state = %{
      state
      | status: :gapped,
        queue: [],
        queued_bytes: 0,
        inflight: nil,
        gap: gap,
        advisory_outstanding: true,
        next_gap: state.next_gap + 1
    }

    {:gap, state, gap, advisory?}
  end

  defp maybe_advise(%{advisory_outstanding: true} = state), do: {:ok, state, false}

  defp maybe_advise(%{status: status} = state) when status in [:ack_required, :recovering],
    do: {:ok, state, false}

  defp maybe_advise(state), do: {:ok, %{state | advisory_outstanding: true}, true}

  defp select_batch(state, events) do
    Enum.reduce_while(events, {[], events}, fn event, {selected, _remaining} ->
      candidate = selected ++ [event]

      cond do
        length(candidate) > state.limits.batch_count ->
          {:halt, {selected, Enum.drop(events, length(selected))}}

        estimated_batch_size(state, candidate) > state.limits.batch_bytes ->
          {:halt, {selected, Enum.drop(events, length(selected))}}

        true ->
          {:cont, {candidate, Enum.drop(events, length(candidate))}}
      end
    end)
    |> case do
      {[], _remaining} -> {[hd(events)], tl(events)}
      result -> result
    end
  end

  defp estimated_batch_size(state, events) do
    encoded_events_size(events) +
      byte_size(state.session_id) + byte_size(state.client_id) + byte_size(state.attachment_id) + 1_024
  end

  defp duplicate?(state, event) do
    identity = {event["id"], event_sequence(event)}

    queued? = Enum.any?(state.queue, &({&1["id"], event_sequence(&1)} == identity))

    inflight? =
      case state.inflight do
        %{first_sequence: first, through_sequence: through} ->
          sequence = event_sequence(event)
          sequence >= first and sequence <= through

        nil ->
          false
      end

    acknowledged? = event_sequence(event) <= state.last_acked
    queued? or inflight? or acknowledged?
  end

  defp require_session(state, %{"session_id" => session_id}) when session_id == state.session_id,
    do: :ok

  defp require_session(_state, _event), do: {:error, :delivery_session_mismatch}

  defp require_identity(state, identity) when is_map(identity) do
    cond do
      get(identity, :session_id) != state.session_id -> {:error, :delivery_identity_mismatch}
      get(identity, :client_id) != state.client_id -> {:error, :delivery_identity_mismatch}
      get(identity, :attachment_id) != state.attachment_id -> {:error, :delivery_identity_mismatch}
      true -> :ok
    end
  end

  defp require_identity(_state, _identity), do: {:error, :delivery_identity_mismatch}

  defp lower_limits(configured) do
    Map.new(@maximums, fn {key, maximum} ->
      configured_value = get(configured, key)
      value = if is_integer(configured_value) and configured_value > 0, do: configured_value, else: maximum
      {key, min(value, maximum)}
    end)
  end

  defp token(state, purpose, parts) do
    data =
      [purpose, state.session_id, state.client_id, state.attachment_id | Enum.map(parts, &to_string/1)]
      |> Enum.join(<<0>>)

    digest = :crypto.mac(:hmac, :sha256, state.secret, data)
    purpose <> "_" <> Base.url_encode64(digest, padding: false)
  end

  defp encoded_events_size(events) do
    Enum.reduce(events, 0, fn event, bytes ->
      case encoded_size(event) do
        {:ok, size} -> bytes + size
        {:error, _reason} -> bytes
      end
    end)
  end

  defp encoded_size(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, byte_size(encoded)}
      {:error, _reason} -> {:error, :nonportable_delivery_value}
    end
  end

  defp event_sequence(event), do: get_in(event, ["payload", "sequence"]) || event["sequence"] || 0

  defp get(map, key) when is_map(map), do: map[key] || map[Atom.to_string(key)]
  defp get(_map, _key), do: nil

  defp bounded_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp bounded_reason(reason), do: reason |> inspect(limit: 10, printable_limit: 200) |> String.slice(0, 256)
end
