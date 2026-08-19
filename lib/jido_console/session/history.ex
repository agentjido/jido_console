defmodule Jido.Console.Session.History do
  @moduledoc "Ordered event history and bounded restart replay."

  alias Jido.Console.Session.{Event, Reducer, State}
  alias Jido.Console.Storage

  @event_limit 10_000

  @doc "Appends one reduced event before live client notification."
  @spec append(map(), State.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def append(event, semantic, _owner, opts \\ []) do
    with {:ok, event} <- Event.validate(event),
         true <- event.session_id == semantic.session_id,
         true <- event.payload["sequence"] == semantic.sequence do
      Storage.append_event(event, semantic, storage_opts(opts))
    else
      false -> {:error, :invalid_semantic_history_position}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Rebuilds semantic state from the complete bounded event log."
  @spec rebuild(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rebuild(session_id, opts \\ []) when is_binary(session_id) do
    started = System.monotonic_time(:microsecond)

    with {:ok, events} <- Storage.events(session_id, storage_opts(opts)),
         {:ok, state} <- Reducer.replay(events, State.new(session_id)) do
      interrupted = not is_nil(state.active_run)
      state = if interrupted, do: %{state | active_run: nil}, else: state

      {:ok,
       %{
         state: state,
         events: length(events),
         interrupted: interrupted,
         rebuild_time_us: System.monotonic_time(:microsecond) - started
       }}
    else
      {:error, :storage_unavailable} = error -> error
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the event replay limit."
  @spec limits() :: map()
  def limits, do: %{events: @event_limit}

  defp storage_opts(opts), do: Keyword.take(opts, [:writer, :deadline])
end
