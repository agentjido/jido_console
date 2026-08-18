defmodule Jido.Console.Session.Reducer do
  @moduledoc """
  Pure reduction of classified Console events into semantic session state.

  Live application and replay use this boundary. The reducer does not call a
  model, tool, or renderer.
  """

  alias Jido.Console.Session.{Event, State}

  @doc "Applies one classified event to semantic state."
  @spec apply_event(State.t(), map()) :: {:ok, State.t()} | {:error, term()}
  def apply_event(state, event) when is_map(event) do
    with :ok <- reject_deprecated_event(event),
         {:ok, event} <- Event.validate(event),
         :ok <- require_session(state, event) do
      reduce(state, event)
    end
  end

  defp reject_deprecated_event(%{"family" => "event", "type" => "delivery_gap"}),
    do: {:error, :deprecated_event_emission}

  defp reject_deprecated_event(_event), do: :ok

  defp reduce(state, event) do
    payload = event["payload"] || %{}
    sequence = payload["sequence"]

    cond do
      Enum.any?(state.history, &(&1["id"] == event["id"])) ->
        {:ok, state}

      not is_integer(sequence) or sequence != state.sequence + 1 ->
        {:error, :invalid_event_order}

      true ->
        state
        |> Map.update!(:sequence, &(&1 + 1))
        |> Map.update!(:history, &(&1 ++ [event]))
        |> put_semantic(event)
        |> then(&with(:ok <- State.validate(&1), do: {:ok, &1}))
    end
  end

  defp require_session(%{session_id: session_id}, %{"session_id" => session_id}), do: :ok
  defp require_session(_state, _event), do: {:error, :cross_session_event}

  @doc "Replays an event stream from initial state."
  @spec replay([map()], State.t()) :: {:ok, State.t()} | {:error, term()}
  def replay(events, state) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, current} ->
      case apply_event(current, event) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "Returns a bounded semantic snapshot."
  @spec snapshot(State.t()) :: map()
  def snapshot(state) do
    %{
      "family" => "snapshot",
      "type" => "session_snapshot",
      "payload" => %{
        "sequence" => state.sequence,
        "protocol_version" => "1",
        "state" => State.to_protocol(state)
      }
    }
  end

  defp put_semantic(state, %{"type" => "run_started"} = event) do
    %{state | active_run: event["payload"]}
  end

  defp put_semantic(state, %{"type" => type}) when type in ["run_completed", "run_failed"],
    do: %{state | active_run: nil}

  defp put_semantic(state, %{"type" => "queue_changed"} = event) do
    queue = if event["payload"]["queue"] == "steering", do: :steering, else: :follow_up
    items = event["payload"]["items"] || []
    %{state | queues: Map.put(state.queues, queue, items)}
  end

  defp put_semantic(state, %{"type" => "input_admitted", "payload" => %{"queue" => queue} = payload}) do
    queue = if queue == "steering", do: :steering, else: :follow_up
    %{state | queues: Map.put(state.queues, queue, payload["items"] || [])}
  end

  defp put_semantic(state, %{"type" => "permission_requested", "payload" => payload}) do
    id = payload["approval_id"]
    request = Map.put(payload, "status", "pending")

    %{
      state
      | pending_interactions: Map.put(state.pending_interactions, id, request),
        permissions: Map.put(state.permissions, id, request)
    }
  end

  defp put_semantic(state, %{"type" => "permission_decided", "payload" => payload}) do
    id = payload["approval_id"]

    permissions =
      Map.update(state.permissions, id, Map.put(payload, "status", "decided"), fn request ->
        request
        |> Map.put("decision", payload["decision"])
        |> Map.put("status", "decided")
      end)

    %{state | pending_interactions: Map.delete(state.pending_interactions, id), permissions: permissions}
  end

  defp put_semantic(state, %{"type" => "control_requested", "payload" => payload}) do
    control = Map.put(payload, "status", "requested")
    %{state | control_state: Map.put(state.control_state, payload["control_id"], control)}
  end

  defp put_semantic(state, %{"type" => "control_completed", "payload" => payload}) do
    id = payload["control_id"]

    controls =
      Map.update(state.control_state, id, Map.put(payload, "status", "terminal"), fn control ->
        control
        |> Map.put("result", payload["result"])
        |> Map.put("status", "terminal")
      end)

    %{state | control_state: controls}
  end

  defp put_semantic(state, _event), do: state
end
