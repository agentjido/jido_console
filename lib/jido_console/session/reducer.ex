defmodule Jido.Console.Session.Reducer do
  @moduledoc """
  Pure reduction of classified Console events into semantic session state.

  Live application and replay use this boundary. The reducer does not call a
  model, tool, or renderer.
  """

  alias Jido.Console.Session.State

  @doc "Applies one classified event to semantic state."
  @spec apply_event(State.t(), map()) :: {:ok, State.t()} | {:error, term()}
  def apply_event(state, event) when is_map(event) do
    payload = event["payload"] || %{}
    sequence = payload["sequence"]

    cond do
      event["session_id"] != state.session_id ->
        {:error, :cross_session_event}

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
    %{state | active_run: event["payload"], transcript: state.transcript ++ [event]}
  end

  defp put_semantic(state, %{"type" => type} = event) when type in ["run_completed", "run_failed"] do
    %{
      state
      | active_run: nil,
        outcomes: state.outcomes ++ [event],
        transcript: state.transcript ++ [event]
    }
  end

  defp put_semantic(state, %{"type" => type} = event) when type in ["control_requested", "control_completed"] do
    %{state | controls: state.controls ++ [event]}
  end

  defp put_semantic(state, %{"type" => "queue_changed"} = event) do
    queue = if event["payload"]["queue"] == "steering", do: :steering, else: :follow_up
    items = event["payload"]["items"] || []
    %{state | queues: Map.put(state.queues, queue, items)}
  end

  defp put_semantic(state, event) do
    %{state | transcript: state.transcript ++ [event]}
  end
end
