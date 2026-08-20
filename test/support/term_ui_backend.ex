defmodule Jido.Console.Test.TermUIBackend do
  @moduledoc false

  @behaviour TermUI.Backend

  @impl true
  def init(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:term_ui_started, self()})

    {:ok,
     %{
       test_pid: test_pid,
       fail_draw?: Keyword.get(opts, :fail_draw, false),
       size: Keyword.get(opts, :size, {16, 60}),
       screen: %{}
     }}
  end

  @impl true
  def shutdown(state) do
    send(state.test_pid, :terminal_closed)
    :ok
  end

  @impl true
  def size(state), do: {:ok, state.size}

  @impl true
  def move_cursor(state, _position), do: {:ok, state}

  @impl true
  def hide_cursor(state), do: {:ok, state}

  @impl true
  def show_cursor(state), do: {:ok, state}

  @impl true
  def clear(state), do: {:ok, %{state | screen: %{}}}

  @impl true
  def draw_cells(%{fail_draw?: true}, _cells), do: {:error, :draw_failed}

  def draw_cells(state, cells) do
    screen = Enum.reduce(cells, state.screen, &put_cell/2)
    send(state.test_pid, {:frame, screen_text(screen, state.size)})
    {:ok, %{state | screen: screen}}
  end

  @impl true
  def flush(state), do: {:ok, state}

  @impl true
  def poll_event(state, _timeout), do: {:timeout, state}

  defp put_cell({position, {character, _foreground, _background, _attributes}}, screen),
    do: Map.put(screen, position, character)

  defp screen_text(screen, {rows, columns}) do
    Enum.map_join(1..rows, "\n", fn row ->
      1..columns
      |> Enum.map_join(&Map.get(screen, {row, &1}, " "))
      |> String.trim_trailing()
    end)
  end
end
