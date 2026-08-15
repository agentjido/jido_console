defmodule Jido.Console.Tui.View do
  @moduledoc "Pure frame renderer for the Jido TUI."

  alias Jido.Console.Tui.{Editor, SafeText, Selection, State}
  alias Jido.Console.Tui.Turn.Tool
  alias Jido.Console.Terminal.Frame

  @spec render(State.t()) :: Frame.t()
  def render(%State{size: {width, 1}}) do
    Frame.new(width, 1, ["Jido · resize"], cursor: nil)
  end

  def render(%State{size: {width, height}}) when width < 12 or height < 5 do
    Frame.new(width, height, ["Jido", "Resize terminal."], cursor: nil)
  end

  def render(%State{size: {width, height}} = state) do
    prompt_limit = min(5, max(height - 4, 1))
    {editor_rows, {cursor_column, cursor_row}} = Editor.render(state.editor, max(width - 2, 1), prompt_limit)
    prompt = prompt_rows(editor_rows)
    body_height = max(height - 3 - length(prompt), 0)
    review = review_rows(state.coding_reviews, width, min(div(height, 2), body_height))
    transcript_height = max(body_height - length(review), 0)
    transcript = transcript_viewport(transcript_rows(state, width), transcript_height, state.scroll_offset)
    divider = String.duplicate("─", width)
    status = status_row(state)

    rows = [title(state)] ++ transcript ++ review ++ [divider, status] ++ prompt
    prompt_start = height - length(prompt) + 1
    cursor = {min(cursor_column + 3, width), prompt_start + cursor_row}
    Frame.new(width, height, rows, cursor: cursor)
  end

  defp prompt_rows([first | rest]), do: ["> " <> first | Enum.map(rest, &("  " <> &1))]

  defp transcript_viewport(_rows, 0, _offset), do: []

  defp transcript_viewport(rows, height, offset) do
    offset = min(offset, max(length(rows) - height, 0))
    stop = length(rows) - offset
    start = max(stop - height, 0)
    visible = Enum.slice(rows, start, height)
    List.duplicate("", height - length(visible)) ++ visible
  end

  defp transcript_rows(state, width) do
    instructions = instruction_rows(state.project_instructions, width)

    if state.turns == [] and is_nil(state.active_turn) do
      instructions ++ legacy_transcript_rows(state, width)
    else
      turns = state.turns ++ if(state.active_turn, do: [state.active_turn], else: [])
      instructions ++ Enum.flat_map(turns, &turn_rows(&1, width))
    end
  end

  defp instruction_rows(instructions, width) do
    instructions
    |> Enum.map(fn instruction ->
      path = SafeText.summary(instruction["path"] || "project instructions")
      scope = SafeText.summary(instruction["scope"] || "project")
      %{role: :project, content: "Loaded #{path} (scope #{scope})"}
    end)
    |> message_rows(width)
  end

  defp legacy_transcript_rows(state, width) do
    messages =
      if state.streaming == "" do
        state.messages
      else
        state.messages ++ [%{role: :assistant, content: state.streaming}]
      end

    message_rows(messages, width)
  end

  defp message_rows(messages, width) do
    Enum.flat_map(messages, fn message ->
      role = role(message.role)
      [role | Frame.wrap(SafeText.clean(message.content), width)] ++ [""]
    end)
  end

  defp turn_rows(turn, width) do
    user = content_rows("User", turn.prompt, width)

    attachments =
      Enum.map(turn.attachments, fn attachment ->
        Frame.fit("  @#{attachment["path"]} · #{attachment["size"] || 0} bytes", width)
      end)

    tools = Enum.flat_map(turn.tool_order, &tool_rows(Map.fetch!(turn.tools, &1), width))
    assistant = content_rows(assistant_role(turn), turn.assistant, width)
    reviews = Enum.flat_map(turn.reviews, &approval_rows(&1, width))
    error = error_rows(turn.outcome, width)
    user ++ attachments ++ tools ++ assistant ++ reviews ++ error
  end

  defp error_rows(%{status: :failed, error: error}, width) when is_binary(error) and error != "",
    do: content_rows("Error", error, width)

  defp error_rows(_outcome, _width), do: []

  defp assistant_role(%{outcome: %{status: :failed}, assistant: assistant}) when assistant != "",
    do: "Assistant (partial)"

  defp assistant_role(_turn), do: "Assistant"

  defp content_rows(_role, "", _width), do: []
  defp content_rows(role, content, width), do: [role | Frame.wrap(content, width)] ++ [""]

  defp tool_rows(%Tool{} = tool, width) do
    operation = SafeText.summary(tool.operation || "tool")
    header = "#{tool_marker(tool.status)} #{operation}"

    detail =
      if tool.summary in [nil, "", operation] do
        []
      else
        ["  #{SafeText.summary(tool.summary)}"]
      end

    Enum.map([header | detail], &Frame.fit(&1, width))
  end

  defp approval_rows(review, width) do
    operation = review |> Map.get(:operation, Map.get(review, "operation")) |> then(&SafeText.summary(&1 || "tool"))
    arguments = review |> Map.get(:arguments_summary, "") |> SafeText.summary()
    status = Map.get(review, :status, :pending)
    decision = Map.get(review, :decision)

    rows =
      case status do
        :pending ->
          ["Review required", "  #{operation}#{arguments_suffix(arguments)}", "  A approve · D deny"]

        :approved ->
          ["[approved] #{operation}#{arguments_suffix(arguments)}"]

        :denied ->
          ["[denied] #{operation}#{arguments_suffix(arguments)}"]

        :expired ->
          ["[expired] #{operation} · #{SafeText.summary(Map.get(review, :error))}"]

        :failed ->
          ["[review failed] #{operation} · #{SafeText.summary(Map.get(review, :error))}"]

        _other when decision in [:approve, :deny] ->
          ["[#{decision}] #{operation}#{arguments_suffix(arguments)}"]

        _other ->
          ["[review #{status}] #{operation}#{arguments_suffix(arguments)}"]
      end

    Enum.map(rows, &Frame.fit(&1, width))
  end

  defp arguments_suffix(arguments) when arguments in [nil, "", "%{}"], do: ""
  defp arguments_suffix(arguments), do: " · #{arguments}"

  defp tool_marker(:planned), do: "[planned]"
  defp tool_marker(:running), do: "[running]"
  defp tool_marker(:completed), do: "[done]"
  defp tool_marker(:failed), do: "[failed]"
  defp tool_marker(:retried), do: "[retried]"
  defp tool_marker(status), do: "[#{status}]"

  defp role(:user), do: "User"
  defp role(:project), do: "Project"
  defp role(:system), do: "System"
  defp role(_role), do: "Assistant"

  defp title(state) do
    {width, _height} = state.size
    Frame.fit(title_prefix(state.selection) <> String.duplicate("─", width), width)
  end

  defp title_prefix(nil), do: " Jido "
  defp title_prefix(selection), do: " Jido · #{Selection.label(selection)} "

  defp review_rows([], _width, _limit), do: []
  defp review_rows(_reviews, _width, 0), do: []

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

    patch = review["patch"] |> SafeText.clean() |> String.split("\n") |> Enum.take(4) |> Enum.map(&("  " <> &1))
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
    do: "startup failed · Esc exits · #{SafeText.summary(error)}"

  defp status_row(%State{scroll_offset: offset}) when offset > 0,
    do: "scroll #{offset} · PgDn follows output"

  defp status_row(%State{status: :idle, error: nil}),
    do: "idle · Enter sends · Ctrl-J newline · Esc exits"

  defp status_row(%State{status: :running}), do: "running · Ctrl-C cancels"
  defp status_row(%State{status: :resolving}), do: "resolving file mentions"
  defp status_row(%State{status: :cancelling}), do: "cancelling"
  defp status_row(%State{status: :review}), do: "review required · A approves · D denies"
  defp status_row(%State{status: :responding_review}), do: "sending review decision"
  defp status_row(%State{status: :interrupted, error: error}), do: SafeText.summary(error || "paused")
  defp status_row(%State{status: :error, error: error}), do: "error · #{SafeText.summary(error)}"
  defp status_row(%State{status: status}), do: Atom.to_string(status)
end
