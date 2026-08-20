defmodule Jido.Console.Test.TermUIBackend do
  @moduledoc false

  @behaviour TermUI.Backend

  @impl true
  def init(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:term_ui_started, Keyword.fetch!(opts, :runtime)})

    {:ok,
     %{
       test_pid: test_pid,
       fail_draw?: Keyword.get(opts, :fail_draw, false),
       fail_flush?: Keyword.get(opts, :fail_flush, false),
       event_queue: Keyword.fetch!(opts, :event_queue),
       size: Keyword.get(opts, :size, {16, 60}),
       frame_count: 0
     }}
  end

  @impl true
  def shutdown(state, _reason) do
    send(state.test_pid, :terminal_closed)
    :ok
  end

  @impl true
  def size(state), do: {:ok, state.size}

  @impl true
  def capabilities(_state), do: %{colors: :true_color, unicode: true}

  @impl true
  def draw(%{fail_draw?: true}, _frame), do: {:error, :draw_failed}

  def draw(state, frame) do
    send(state.test_pid, {:frame, frame_text(frame)})
    send(state.test_pid, {:term_ui_frame, frame})
    {:ok, %{state | frame_count: state.frame_count + 1}}
  end

  @impl true
  def flush(%{fail_flush?: true}), do: {:error, :flush_failed}
  def flush(state), do: {:ok, state}

  @impl true
  def poll_event(state, timeout) do
    case Agent.get_and_update(state.event_queue, fn queue ->
           case :queue.out(queue) do
             {{:value, event}, rest} -> {{:event, event}, rest}
             {:empty, queue} -> {:empty, queue}
           end
         end) do
      {:event, event} ->
        {:ok, event, state}

      :empty ->
        Process.sleep(min(timeout, 5))
        {:timeout, state}
    end
  end

  @impl true
  def resize(state, size), do: {:ok, %{state | size: size}}

  @impl true
  def clipboard(state, operation) do
    send(state.test_pid, {:clipboard, operation})
    {:ok, state}
  end

  defp frame_text(frame) do
    1..frame.height
    |> Enum.map_join("\n", fn row -> frame |> TermUI.Frame.row_text(row) |> String.trim_trailing() end)
  end
end
