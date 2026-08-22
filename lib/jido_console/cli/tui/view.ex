defmodule Jido.Console.Tui.View do
  @moduledoc "Pure frame renderer for the Jido TUI."

  alias Jido.Console.Tui.{Activity, Editor, SafeText, Selection, State}
  alias Jido.Console.Tui.Turn.Tool
  alias Jido.Console.Terminal.TextLayout
  alias TermUI.{Frame, Markdown, Style}
  alias TermUI.Widget.DiffViewer

  @max_rendered_turns 200
  @max_transcript_rows 2_000
  @max_markdown_bytes 512_000
  @max_diff_rows 200
  @max_frame_width 1_000
  @max_frame_height 500

  @spec render(State.t()) :: Frame.t()
  def render(%State{} = state) do
    state
    |> normalize_frame_size()
    |> render_frame()
  end

  defp render_frame(%State{size: {width, 1}}) do
    Frame.from_rows(["Jido · resize"], width, 1)
  end

  defp render_frame(%State{size: {width, height}}) when width < 12 or height < 5 do
    Frame.from_rows(["Jido", "Resize terminal."], width, height)
  end

  defp render_frame(%State{size: {width, height}} = state) do
    prompt_limit = min(5, max(height - 4, 1))
    editor = Editor.frame(state.editor, max(width - 2, 1), prompt_limit)
    body_height = max(height - 3 - editor.height, 0)
    review = review_rows(state.coding_reviews, width, min(div(height, 2), body_height))
    transcript_height = max(body_height - length(review), 0)
    row_limit = min(transcript_height + state.scroll_offset, @max_transcript_rows)
    transcript = transcript_viewport(transcript_rows(state, width, row_limit), transcript_height, state.scroll_offset)
    divider = String.duplicate("─", width)
    status = status_row(state)

    prompt = for row <- 1..editor.height, do: if(row == 1, do: "> ", else: "  ")
    rows = [title(state)] ++ transcript ++ review ++ [divider, status] ++ prompt
    prompt_start = height - editor.height + 1

    rows
    |> Frame.from_rows(width, height)
    |> Frame.overlay(editor, 3, prompt_start)
  end

  defp transcript_viewport(_rows, 0, _offset), do: []

  defp transcript_viewport(rows, height, offset) do
    offset = min(offset, max(length(rows) - height, 0))
    stop = length(rows) - offset
    start = max(stop - height, 0)
    visible = Enum.slice(rows, start, height)
    List.duplicate("", height - length(visible)) ++ visible
  end

  defp transcript_rows(_state, _width, 0), do: []

  defp transcript_rows(state, width, row_limit) do
    active_turn = State.active_turn(state)

    if state.turns == [] and is_nil(active_turn) do
      recent_rows(state.messages, row_limit, &message_rows([&1], width, row_limit))
      |> prepend_instructions(state.project_instructions, width, row_limit)
    else
      turns = state.turns ++ if(active_turn, do: [active_turn], else: [])

      turns
      |> Enum.take(-@max_rendered_turns)
      |> recent_rows(row_limit, &turn_rows(&1, width, row_limit))
      |> prepend_instructions(state.project_instructions, width, row_limit)
    end
  end

  defp recent_rows(items, limit, render) do
    items
    |> Enum.reverse()
    |> Enum.reduce_while([], fn item, rows ->
      if length(rows) >= limit do
        {:halt, rows}
      else
        block = render.(item)
        {:cont, Enum.take(block ++ rows, -limit)}
      end
    end)
  end

  defp prepend_instructions(rows, _instructions, _width, limit) when length(rows) >= limit,
    do: rows

  defp prepend_instructions(rows, instructions, width, limit) do
    (instruction_rows(instructions, width) ++ rows)
    |> Enum.take(-limit)
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

  defp message_rows(messages, width) do
    Enum.flat_map(messages, &message_block(&1, width, @max_transcript_rows))
  end

  defp message_rows(messages, width, limit) do
    Enum.flat_map(messages, &message_block(&1, width, limit))
  end

  defp message_block(message, width, limit) do
    case role(message.role) do
      "Assistant" -> markdown_rows("Assistant", message.content, width, limit)
      label -> content_rows(label, message.content, width, limit)
    end
  end

  defp turn_rows(turn, width, limit) do
    user = content_rows("User", turn.prompt, width, limit)

    attachments =
      Enum.map(turn.attachments, fn attachment ->
        TextLayout.fit("  @#{attachment["path"]} · #{attachment["size"] || 0} bytes", width)
      end)

    tools = Enum.flat_map(turn.tool_order, &tool_rows(Map.fetch!(turn.tools, &1), width))
    assistant = markdown_rows(assistant_role(turn), turn.assistant, width, limit)
    reviews = Enum.flat_map(turn.reviews, &approval_rows(&1, width))
    error = error_rows(turn.outcome, width)

    (user ++ attachments ++ tools ++ assistant ++ reviews ++ error)
    |> Enum.take(-limit)
  end

  defp error_rows(%{status: :failed, error: error}, width) when is_binary(error) and error != "",
    do: content_rows("Error", error, width)

  defp error_rows(_outcome, _width), do: []

  defp assistant_role(%{outcome: %{status: :failed}, assistant: assistant}) when assistant != "",
    do: "Assistant (partial)"

  defp assistant_role(_turn), do: "Assistant"

  defp content_rows(_role, "", _width), do: []
  defp content_rows(role, content, width), do: [role | TextLayout.wrap(content, width)] ++ [""]

  defp content_rows(_role, "", _width, _limit), do: []

  defp content_rows(role, content, width, limit) do
    ([role] ++ TextLayout.wrap_tail(content, width, max(limit - 2, 1)) ++ [""])
    |> Enum.take(-limit)
  end

  defp markdown_rows(_role, "", _width, _limit), do: []

  defp markdown_rows(role, content, width, limit) do
    byte_limit = min(@max_markdown_bytes, max(limit * width * 8, 4_096))

    rendered =
      content
      |> TextLayout.retain_tail(byte_limit)
      |> Markdown.render(width)
      |> Enum.take(-max(limit - 2, 1))

    ([role] ++ rendered ++ [""])
    |> Enum.take(-limit)
  end

  defp tool_rows(%Tool{} = tool, width) do
    operation = SafeText.summary(tool.operation || "tool")
    header = "#{tool_marker(tool.status)} #{operation}"

    detail =
      if tool.summary in [nil, "", operation] do
        []
      else
        ["  #{SafeText.summary(tool.summary)}"]
      end

    Enum.map([header | detail], &TextLayout.fit(&1, width))
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

    Enum.map(rows, &TextLayout.fit(&1, width))
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
    TextLayout.fit(title_prefix(state.selection) <> String.duplicate("─", width), width)
  end

  defp title_prefix(nil), do: " Jido "
  defp title_prefix(selection), do: " Jido · #{Selection.label(selection)} "

  defp review_rows([], _width, _limit), do: []
  defp review_rows(_reviews, _width, 0), do: []

  defp review_rows(reviews, width, limit) do
    {rows, truncated?} =
      Enum.reduce_while(reviews, {["Review"], false}, fn review, {rows, _truncated?} ->
        remaining = limit - length(rows)

        if remaining == 0 do
          {:halt, {rows, true}}
        else
          {review_rows, truncated?} = review_record(review, width, remaining)
          rows = rows ++ review_rows

          if truncated? do
            {:halt, {rows, true}}
          else
            {:cont, {rows, false}}
          end
        end
      end)

    if truncated?,
      do: List.replace_at(rows, -1, TextLayout.fit("… review truncated", width)),
      else: rows
  end

  defp normalize_frame_size(%State{size: {width, height}} = state) do
    %{state | size: {min(width, @max_frame_width), min(height, @max_frame_height)}}
  end

  defp review_record(%{"kind" => "edit"} = review, width, limit) do
    header =
      "#{marker(review["status"])} #{review["path"]} · #{review["operation"] || "edit"} · " <>
        "#{review["before_sha256"] || "new"} → #{review["after_sha256"]}"

    checkpoint = if review["checkpoint_ref"], do: ["  checkpoint #{review["checkpoint_ref"]}"], else: []
    diff = structural_diff_rows(review["diff"])
    limited_review_rows([header] ++ checkpoint ++ diff, width, limit)
  end

  defp review_record(%{"kind" => "git_diff"} = review, width, limit) do
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

    file_rows = Enum.map([header] ++ files, &TextLayout.fit(&1, width))
    remaining = limit - length(file_rows)

    if remaining <= 0 do
      {Enum.take(file_rows, limit), true}
    else
      {patch, truncated?} = diff_rows(review["patch"], width, remaining)
      {file_rows ++ patch, truncated?}
    end
  end

  defp review_record(review, width, limit) do
    header = "#{marker(review["status"])} #{review["path"] || "coding mutation"} · #{review["status"]}"
    checkpoint = if review["checkpoint_ref"], do: ["  checkpoint #{review["checkpoint_ref"]}"], else: []
    message = if review["message"], do: ["  #{review["message"]}"], else: []
    limited_review_rows([header] ++ checkpoint ++ message, width, limit)
  end

  defp limited_review_rows(rows, width, limit) do
    rows = Enum.map(rows, &TextLayout.fit(&1, width))
    {Enum.take(rows, limit), length(rows) > limit}
  end

  defp diff_rows(patch, width, limit) do
    inner_width = max(width - 2, 1)

    viewer =
      DiffViewer.init(
        unified_diff: SafeText.clean(patch || ""),
        max_lines: min(@max_diff_rows, limit),
        context: 3
      )

    full_height = min(max(length(viewer.rows) * 2 + 2, 1), @max_diff_rows)
    height = min(full_height, limit)

    rows =
      viewer
      |> DiffViewer.view({inner_width, height})
      |> styled_frame_rows()
      |> Enum.map(&[{"  ", Style.new()} | &1])

    {rows, full_height > height}
  end

  defp styled_frame_rows(frame) do
    Enum.map(1..frame.height, fn row ->
      last_column =
        frame.cells
        |> Enum.flat_map(fn
          {{^row, column}, cell} when not cell.wide_placeholder -> [column]
          _entry -> []
        end)
        |> Enum.max(fn -> 0 end)

      if last_column == 0 do
        []
      else
        1..last_column
        |> Enum.flat_map(&styled_frame_cell(frame, row, &1))
      end
    end)
  end

  defp styled_frame_cell(frame, row, column) do
    cell = Frame.cell(frame, row, column)

    if cell.wide_placeholder,
      do: [],
      else: [{cell.char, %Style{fg: cell.fg, bg: cell.bg, attrs: cell.attrs}}]
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

  defp status_row(%State{activity: {:failed, :startup, _reason, error}}),
    do: "startup failed · Esc exits · #{SafeText.summary(error)}"

  defp status_row(%State{startup: :starting, activity: {:starting, {:turn, _turn}}}),
    do: "prompt queued · starting runtime · Esc exits"

  defp status_row(%State{startup: :starting, activity: {:cancelling, _turn, :before_start}}),
    do: "prompt cancelled · starting runtime · Esc exits"

  defp status_row(%State{startup: :starting}),
    do: "starting runtime · Enter queues prompt · Esc exits"

  defp status_row(%State{scroll_offset: offset}) when offset > 0,
    do: "scroll #{offset} · PgDn follows output"

  defp status_row(%State{activity: :idle}),
    do: "idle · Enter sends · Ctrl-J newline · Esc exits"

  defp status_row(%State{activity: {:starting, {:turn, _turn}}}), do: "starting turn · Ctrl-C cancels"

  defp status_row(%State{activity: {:active, _request, _turn, _phase}} = state) do
    queued =
      case state.session do
        %Jido.Console.Session.View{queue: []} -> ""
        %Jido.Console.Session.View{queue: queue} -> " · #{length(queue)} queued"
        _session -> ""
      end

    "running#{queued} · Enter queues · Ctrl-C cancels"
  end

  defp status_row(%State{activity: {:cancelling, _turn, _target}}), do: "cancelling"

  defp status_row(%State{activity: {:review, _request, _turn, _result, :awaiting}}),
    do: "review required · A approves · D denies"

  defp status_row(%State{activity: {:review, _request, _turn, _result, {:responding, _decision}}}),
    do: "sending review decision"

  defp status_row(%State{activity: {:failed, :hibernated, _reason, error}}),
    do: SafeText.summary(error)

  defp status_row(%State{activity: {:failed, _kind, _reason, error}}),
    do: "error · #{SafeText.summary(error)}"

  defp status_row(%State{activity: activity}), do: Activity.tag(activity) |> Atom.to_string()
end
