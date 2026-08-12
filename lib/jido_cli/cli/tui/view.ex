defmodule Jido.Cli.Tui.View do
  @moduledoc "Pure frame renderer for the Jido TUI."

  alias Jido.Cli.Tui.Editor
  alias Jido.Cli.Tui.State
  alias Jido.Terminal.Frame

  @spec render(State.t()) :: Frame.t()
  def render(%State{size: {width, height}}) when width < 12 or height < 5 do
    Frame.new(width, height, ["Jido", "Terminal is too small."], cursor: nil)
  end

  def render(%State{size: {width, height}} = state) do
    transcript_height = height - 4
    transcript = transcript_rows(state, width) |> Enum.take(-transcript_height)
    transcript = List.duplicate("", transcript_height - length(transcript)) ++ transcript
    divider = String.duplicate("─", width)
    status = status_row(state)
    {prompt, cursor_offset} = Editor.visible(state.editor, max(width - 2, 1))
    prompt_row = "> " <> prompt

    rows = [title(width)] ++ transcript ++ [divider, status, prompt_row]
    Frame.new(width, height, rows, cursor: {min(cursor_offset + 3, width), height})
  end

  defp transcript_rows(state, width) do
    messages =
      if state.streaming == "" do
        state.messages
      else
        state.messages ++ [%{role: :assistant, content: state.streaming}]
      end

    Enum.flat_map(messages, fn message ->
      role = if message.role == :user, do: "User", else: "Assistant"
      [role | Frame.wrap(message.content, width)] ++ [""]
    end)
  end

  defp title(width), do: Frame.fit(" Jido " <> String.duplicate("─", width), width)

  defp status_row(%State{status: :idle, error: nil}), do: "idle · Enter sends · Esc exits"
  defp status_row(%State{status: :running}), do: "running · Ctrl-C cancels"
  defp status_row(%State{status: :cancelling}), do: "cancelling"
  defp status_row(%State{status: :interrupted, error: error}), do: error || "paused"
  defp status_row(%State{status: :error, error: error}), do: "error · #{error}"
  defp status_row(%State{status: status}), do: Atom.to_string(status)
end
