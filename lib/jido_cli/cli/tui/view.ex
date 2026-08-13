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
    review = review_rows(state.coding_reviews, width, max(div(height, 2), 1))
    transcript_height = max(height - 4 - length(review), 0)
    transcript = transcript_rows(state, width) |> Enum.take(-transcript_height)
    transcript = List.duplicate("", transcript_height - length(transcript)) ++ transcript
    divider = String.duplicate("─", width)
    status = status_row(state)
    {prompt, cursor_offset} = Editor.visible(state.editor, max(width - 2, 1))
    prompt_row = "> " <> prompt

    rows = [title(width)] ++ transcript ++ review ++ [divider, status, prompt_row]
    Frame.new(width, height, rows, cursor: {min(cursor_offset + 3, width), height})
  end

  defp transcript_rows(state, width) do
    instructions =
      Enum.map(state.project_instructions, fn instruction ->
        %{role: :project, content: "Loaded #{instruction["path"]} (scope #{instruction["scope"]})"}
      end)

    messages =
      if state.streaming == "" do
        instructions ++ state.messages
      else
        instructions ++ state.messages ++ [%{role: :assistant, content: state.streaming}]
      end

    Enum.flat_map(messages, fn message ->
      role = role(message.role)
      [role | Frame.wrap(message.content, width)] ++ [""]
    end)
  end

  defp role(:user), do: "User"
  defp role(:project), do: "Project"
  defp role(_role), do: "Assistant"

  defp title(width), do: Frame.fit(" Jido " <> String.duplicate("─", width), width)

  defp review_rows([], _width, _limit), do: []

  defp review_rows(reviews, width, limit) do
    all_rows = ["Review"] ++ Enum.flat_map(reviews, &review_record(&1, width))
    rows = Enum.take(all_rows, limit)

    if length(rows) < length(all_rows),
      do: List.replace_at(rows, -1, Frame.fit("… review truncated", width)),
      else: rows
  end

  defp review_record(%{"kind" => "edit"} = review, width) do
    header =
      "#{marker(review["status"])} #{review["path"]} · #{review["operation"] || "edit"} · " <>
        "#{review["before_sha256"] || "new"} → #{review["after_sha256"]}"

    checkpoint = if review["checkpoint_ref"], do: ["  checkpoint #{review["checkpoint_ref"]}"], else: []
    diff = structural_diff_rows(review["diff"])
    Enum.map([header] ++ checkpoint ++ diff, &Frame.fit(&1, width))
  end

  defp review_record(%{"kind" => "git_diff"} = review, width) do
    file_count = length(review["files"])
    file_label = if file_count == 1, do: "file", else: "files"

    header =
      "#{marker(review["status"])} Git diff · #{file_count} #{file_label}" <>
        if(review["binary"], do: " · binary", else: "") <>
        if(review["truncated"], do: " · truncated", else: "")

    files =
      Enum.map(review["files"], fn file ->
        facts = if file["binary"], do: "binary", else: "+#{file["additions"] || 0} -#{file["deletions"] || 0}"
        "  #{file["path"]} · #{facts}"
      end)

    patch = review["patch"] |> String.split("\n") |> Enum.take(4) |> Enum.map(&("  " <> &1))
    Enum.map([header] ++ files ++ patch, &Frame.fit(&1, width))
  end

  defp review_record(review, width) do
    header = "#{marker(review["status"])} #{review["path"] || "coding mutation"} · #{review["status"]}"
    checkpoint = if review["checkpoint_ref"], do: ["  checkpoint #{review["checkpoint_ref"]}"], else: []
    message = if review["message"], do: ["  #{review["message"]}"], else: []
    Enum.map([header] ++ checkpoint ++ message, &Frame.fit(&1, width))
  end

  defp structural_diff_rows(%{"redacted" => true}), do: ["  diff redacted"]

  defp structural_diff_rows(diff) when is_map(diff) do
    [
      "  lines #{diff["before_lines"] || 0} → #{diff["after_lines"] || 0}; " <>
        "changed -#{diff["changed_before_lines"] || 0} +#{diff["changed_after_lines"] || 0}"
    ]
  end

  defp structural_diff_rows(_diff), do: []

  defp marker("changed"), do: "[changed]"
  defp marker("no_change"), do: "[no change]"
  defp marker("restored"), do: "[restored]"
  defp marker("conflict"), do: "[conflict]"
  defp marker("cancelled"), do: "[cancelled]"
  defp marker("interrupted"), do: "[interrupted]"
  defp marker(_status), do: "[failed]"

  defp status_row(%State{runtime_status: :starting, submit_when_ready?: true}),
    do: "starting runtime · prompt queued"

  defp status_row(%State{runtime_status: :starting}),
    do: "starting runtime · Enter queues"

  defp status_row(%State{runtime_status: :failed, error: error}),
    do: "startup failed · Esc exits · #{error}"

  defp status_row(%State{status: :idle, error: nil}), do: "idle · Enter sends · Esc exits"
  defp status_row(%State{status: :running}), do: "running · Ctrl-C cancels"
  defp status_row(%State{status: :resolving}), do: "resolving file mentions"
  defp status_row(%State{status: :cancelling}), do: "cancelling"
  defp status_row(%State{status: :interrupted, error: error}), do: error || "paused"
  defp status_row(%State{status: :error, error: error}), do: "error · #{error}"
  defp status_row(%State{status: status}), do: Atom.to_string(status)
end
