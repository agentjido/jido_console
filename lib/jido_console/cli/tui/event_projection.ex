defmodule Jido.Console.Tui.EventProjection do
  @moduledoc false

  alias Jido.Console.Tui.SafeText
  alias Jidoka.Event
  alias Jidoka.Stream

  @tool_events [
    :effect_planned,
    :effect_started,
    :effect_replayed,
    :effect_completed,
    :effect_failed,
    :capability_call_started,
    :capability_call_completed,
    :capability_call_failed,
    :operation_observed
  ]
  @review_events [
    :policy_review_requested,
    :control_interrupted,
    :approval_requested,
    :approval_responded,
    :approval_applied
  ]
  @terminal_events [:turn_finished, :turn_hibernated, :turn_failed]

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.any(),
              request_id: Zoi.string(),
              seq: Zoi.integer() |> Zoi.gte(0),
              event: Zoi.atom(),
              kind: Zoi.enum([:assistant_delta, :tool, :review, :outcome, :event]),
              data: Zoi.map()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type kind :: :assistant_delta | :tool | :review | :outcome | :event
  @type t :: %__MODULE__{
          id: tuple(),
          request_id: String.t(),
          seq: non_neg_integer(),
          event: atom(),
          kind: kind(),
          data: map()
        }

  @spec project(term()) :: {:ok, t()} | {:error, term()}
  def project(%Event{request_id: request_id, seq: seq} = event)
      when is_binary(request_id) and request_id != "" and is_integer(seq) and seq >= 0 do
    {:ok,
     %__MODULE__{
       id: event_id(event),
       request_id: request_id,
       seq: seq,
       event: event.event,
       kind: kind(event),
       data: data(event)
     }}
  end

  def project(%Event{request_id: request_id, seq: seq})
      when is_binary(request_id) and request_id != "",
      do: {:error, {:invalid_event_sequence, seq}}

  def project(%Event{request_id: request_id}), do: {:error, {:invalid_event_request_id, request_id}}
  def project(_event), do: {:error, :invalid_jidoka_event}

  defp event_id(event) do
    {event.request_id, event.seq, event.event, event.effect_id, interrupt_id(event), event.operation}
  end

  defp kind(%Event{event: :llm_delta} = event) do
    if is_binary(Stream.text_delta(event)), do: :assistant_delta, else: :event
  end

  defp kind(%Event{event: event, effect_kind: :operation}) when event in @tool_events, do: :tool
  defp kind(%Event{event: :operation_observed}), do: :tool
  defp kind(%Event{event: event}) when event in @review_events, do: :review
  defp kind(%Event{event: event}) when event in @terminal_events, do: :outcome
  defp kind(%Event{}), do: :event

  defp data(%Event{} = event) do
    case kind(event) do
      :assistant_delta -> %{text: event |> Stream.text_delta() |> SafeText.clean()}
      :tool -> tool_data(event)
      :review -> review_data(event)
      :outcome -> outcome_data(event)
      :event -> %{}
    end
  end

  defp tool_data(event) do
    %{
      id: event.effect_id || {:observation, event.seq},
      operation: safe_optional(event.operation),
      status: tool_status(event.event),
      loop_index: event.loop_index,
      summary: tool_summary(event),
      error: safe_optional(event.error)
    }
  end

  defp review_data(event) do
    %{
      id: interrupt_id(event) || {:review, event.seq},
      operation: safe_optional(event.operation || Map.get(event.data, :operation)),
      status: review_status(event.event, event.status),
      reason: safe_optional(Map.get(event.data, :reason)),
      decision: Map.get(event.data, :decision),
      expires_at_ms: Map.get(event.data, :expires_at_ms),
      summary: SafeText.summary(event.data)
    }
  end

  defp outcome_data(event) do
    %{
      status: outcome_status(event.event),
      error: safe_optional(event.error || Map.get(event.data, :reason)),
      summary: SafeText.summary(event.data)
    }
  end

  defp interrupt_id(%Event{data: data}) when is_map(data), do: Map.get(data, :interrupt_id)

  defp tool_status(:effect_planned), do: :planned
  defp tool_status(:effect_replayed), do: :retried
  defp tool_status(event) when event in [:effect_started, :capability_call_started], do: :running

  defp tool_status(event)
       when event in [:effect_completed, :capability_call_completed, :operation_observed],
       do: :completed

  defp tool_status(event) when event in [:effect_failed, :capability_call_failed], do: :failed

  defp review_status(event, status) when event in [:approval_responded, :approval_applied],
    do: status || :completed

  defp review_status(_event, status), do: status || :pending

  defp outcome_status(:turn_finished), do: :completed
  defp outcome_status(:turn_hibernated), do: :hibernated
  defp outcome_status(:turn_failed), do: :failed

  defp tool_summary(event) do
    value =
      cond do
        event.error -> event.error
        map_size(event.data) > 0 -> event.data
        event.operation -> event.operation
        true -> event.event
      end

    SafeText.summary(value)
  end

  defp safe_optional(nil), do: nil
  defp safe_optional(value), do: SafeText.summary(value)
end
