defmodule Jido.Console.Tui.View do
  @moduledoc "Pure frame renderer for the Jido TUI."

  alias Jido.Console.Tui.{Activity, Editor, SafeText, Selection, State}
  alias Jido.Console.Tui.Turn.Tool
  alias Jido.Console.Terminal.TextLayout
  alias TermUI.{DisplayWidth, Frame, Markdown, Style}
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

    transcript =
      transcript_viewport(
        transcript_rows(state, width, row_limit),
        transcript_height,
        state.scroll_offset,
        transcript_alignment(state)
      )

    divider = String.duplicate("─", width)
    status = status_row(state)

    prompt = for row <- 1..editor.height, do: if(row == 1, do: "> ", else: "  ")
    rows = [title(state)] ++ transcript ++ review ++ [divider, status] ++ prompt
    prompt_start = height - editor.height + 1

    rows
    |> Frame.from_rows(width, height)
    |> Frame.overlay(editor, 3, prompt_start)
  end

  defp transcript_viewport(_rows, 0, _offset, _alignment), do: []

  defp transcript_viewport(rows, height, _offset, :welcome) do
    rows = Enum.take(rows, height)
    open_rows = height - length(rows)
    top = div(open_rows, 3)
    List.duplicate("", top) ++ rows ++ List.duplicate("", open_rows - top)
  end

  defp transcript_viewport(rows, height, _offset, :top) do
    rows = Enum.take(rows, height)
    rows ++ List.duplicate("", height - length(rows))
  end

  defp transcript_viewport(rows, height, offset, :bottom) do
    if offset == 0 and length(rows) <= height do
      rows ++ List.duplicate("", height - length(rows))
    else
      offset = min(offset, max(length(rows) - height, 0))
      stop = length(rows) - offset
      start = max(stop - height, 0)
      visible = Enum.slice(rows, start, height)
      List.duplicate("", height - length(visible)) ++ visible
    end
  end

  defp transcript_alignment(%State{activity: {:failed, :startup, _reason, _error}}), do: :top

  defp transcript_alignment(%State{} = state) do
    if state.turns == [] and is_nil(State.active_turn(state)) and state.messages == [] and
         state.project_instructions == [],
       do: :welcome,
       else: :bottom
  end

  defp transcript_rows(_state, _width, 0), do: []

  defp transcript_rows(%State{activity: {:failed, :startup, _reason, error}}, width, row_limit) do
    startup_failure_rows(error, width, row_limit)
  end

  defp transcript_rows(state, width, row_limit) do
    active_turn = State.active_turn(state)

    if state.turns == [] and is_nil(active_turn) do
      if state.messages == [] and state.project_instructions == [] do
        welcome_rows(state, width, row_limit)
      else
        recent_rows(state.messages, row_limit, &message_rows([&1], width, row_limit))
        |> prepend_instructions(state.project_instructions, width, row_limit)
      end
    else
      turns = state.turns ++ if(active_turn, do: [active_turn], else: [])

      turns
      |> Enum.take(-@max_rendered_turns)
      |> recent_rows(row_limit, &turn_rows(&1, width, row_limit))
      |> prepend_instructions(state.project_instructions, width, row_limit)
    end
  end

  defp welcome_rows(state, width, row_limit) do
    selection = state.selection || %{}
    model = Map.get(selection, :model) || "not selected"
    tier = Map.get(selection, :model_tier)
    model = if tier, do: "#{model} (#{tier})", else: model
    profile = Map.get(selection, :profile_id) || "not selected"
    workspace = state.project_root || "current directory"

    action =
      if state.startup == :starting,
        do: "You can type now. Enter queues the task while Jido starts.",
        else: "Type a task below and press Enter."

    title = if state.startup == :starting, do: "Starting Jido", else: "Jido is ready"

    [
      title,
      "",
      action,
      "",
      "Model     #{SafeText.summary(model)}",
      "Profile   #{SafeText.summary(profile)}",
      "Workspace #{SafeText.summary(workspace)}",
      "",
      "Try: Explain this project and suggest the next small change."
    ]
    |> fit_priority_rows(width, row_limit)
  end

  defp startup_failure_rows(error, width, row_limit) do
    rows =
      ["Jido could not start", ""] ++
        TextLayout.wrap(SafeText.clean(error), width) ++
        ["", "Fix the error above, then start Jido again.", "Press Esc to exit."]

    rows
    |> Enum.take(row_limit)
    |> Enum.map(&TextLayout.fit(&1, width))
  end

  defp fit_priority_rows(rows, width, row_limit) when row_limit < length(rows) do
    rows
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(row_limit)
    |> Enum.map(&TextLayout.fit(&1, width))
  end

  defp fit_priority_rows(rows, width, _row_limit), do: Enum.map(rows, &TextLayout.fit(&1, width))

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
      "JIDO" -> markdown_rows("JIDO", message.content, width, limit)
      label -> content_rows(label, message.content, width, limit)
    end
  end

  defp turn_rows(turn, width, limit) do
    user = content_rows("YOU", turn.prompt, width, limit)

    attachments =
      Enum.map(turn.attachments, fn attachment ->
        TextLayout.fit("  @#{attachment["path"]} · #{attachment["size"] || 0} bytes", width)
      end)

    tools =
      turn.tool_order
      |> Enum.with_index()
      |> Enum.flat_map(fn {id, index} ->
        tool_rows(Map.fetch!(turn.tools, id), width, index == length(turn.tool_order) - 1)
      end)

    assistant = markdown_body_rows(turn.assistant, width, limit)
    reviews = Enum.flat_map(turn.reviews, &approval_rows(&1, width))
    error = error_rows(turn.outcome, width)
    agent_body = tools ++ assistant ++ reviews ++ error

    agent =
      if agent_body == [] do
        []
      else
        [role_row(assistant_role(turn))] ++ agent_body ++ [""]
      end

    (user ++ attachments ++ agent)
    |> Enum.take(-limit)
  end

  defp error_rows(%{status: :failed, error: error}, width) when is_binary(error) and error != "",
    do: timeline_notice_rows("✗ FAILED", error, width, :failed)

  defp error_rows(_outcome, _width), do: []

  defp assistant_role(%{outcome: %{status: :failed}, assistant: assistant}) when assistant != "",
    do: "JIDO · PARTIAL"

  defp assistant_role(_turn), do: "JIDO"

  defp content_rows(_role, "", _width, _limit), do: []

  defp content_rows(role, content, width, limit) do
    rows = TextLayout.wrap_tail(content, max(width - 2, 1), max(limit - 2, 1))

    ([role_row(role)] ++ indent_text_rows(rows, width) ++ [""])
    |> Enum.take(-limit)
  end

  defp markdown_rows(_role, "", _width, _limit), do: []

  defp markdown_rows(role, content, width, limit) do
    ([role_row(role)] ++ markdown_body_rows(content, width, limit) ++ [""])
    |> Enum.take(-limit)
  end

  defp markdown_body_rows("", _width, _limit), do: []

  defp markdown_body_rows(content, width, limit) do
    byte_limit = min(@max_markdown_bytes, max(limit * width * 8, 4_096))
    inner_width = max(width - 2, 1)

    content
    |> TextLayout.retain_tail(byte_limit)
    |> Markdown.render(inner_width)
    |> Enum.take(-max(limit - 1, 1))
    |> Enum.map(&[{"  ", Style.new()} | &1])
  end

  defp indent_text_rows(rows, width) do
    Enum.map(rows, &TextLayout.fit("  " <> &1, width))
  end

  defp role_row("YOU"), do: [{"YOU", Style.new(fg: :cyan, attrs: [:bold])}]
  defp role_row("JIDO"), do: [{"JIDO", Style.new(attrs: [:bold])}]
  defp role_row("JIDO · PARTIAL"), do: [{"JIDO · PARTIAL", Style.new(fg: :cyan, attrs: [:bold])}]
  defp role_row(role), do: [{role, Style.new(fg: :bright_black, attrs: [:bold])}]

  defp timeline_notice_rows(label, content, width, status) do
    [
      [{"  #{label}", timeline_status_style(status)}]
      | indent_text_rows(TextLayout.wrap(content, max(width - 4, 1)), width)
    ]
  end

  defp tool_rows(%Tool{} = tool, width, last?) do
    operation = SafeText.summary(tool.operation || "tool")
    connector = if(last?, do: "└─", else: "├─")
    {symbol, label, style} = tool_status(tool.status)
    prefix = "  #{connector} #{symbol} #{label}  "
    available = max(width - DisplayWidth.string_width(prefix), 0)
    {operation, _operation_width} = DisplayWidth.truncate(operation, available)

    [
      [
        {"  #{connector} ", Style.new(fg: :bright_black)},
        {"#{symbol} #{label}", style},
        {"  #{operation}", Style.new()}
      ]
    ]
  end

  defp tool_status(:planned), do: {"○", "PLANNED", timeline_status_style(:planned)}
  defp tool_status(:running), do: {"●", "RUNNING", timeline_status_style(:running)}
  defp tool_status(:completed), do: {"✓", "DONE", timeline_status_style(:completed)}
  defp tool_status(:failed), do: {"✗", "FAILED", timeline_status_style(:failed)}
  defp tool_status(:cancelled), do: {"■", "CANCELLED", timeline_status_style(:cancelled)}
  defp tool_status(:replayed), do: {"↻", "REPLAYED", timeline_status_style(:replayed)}
  defp tool_status(status), do: {"•", status |> to_string() |> String.upcase(), timeline_status_style(:planned)}

  defp timeline_status_style(:planned), do: Style.new(fg: :bright_black)
  defp timeline_status_style(:running), do: Style.new(fg: :cyan, attrs: [:bold])
  defp timeline_status_style(:completed), do: Style.new(fg: :green)
  defp timeline_status_style(:failed), do: Style.new(fg: :red, attrs: [:bold])
  defp timeline_status_style(:cancelled), do: Style.new(fg: :yellow)
  defp timeline_status_style(:replayed), do: Style.new(fg: :blue)
  defp timeline_status_style(:review), do: Style.new(fg: :yellow, attrs: [:bold])

  defp approval_rows(review, width) do
    operation = review |> Map.get(:operation, Map.get(review, "operation")) |> then(&SafeText.summary(&1 || "tool"))
    arguments = review |> Map.get(:arguments_summary, "") |> SafeText.summary()
    status = Map.get(review, :status, :pending)
    decision = Map.get(review, :decision)

    rows =
      case status do
        :pending ->
          [
            [{"  ◆ REVIEW REQUIRED", timeline_status_style(:review)}],
            TextLayout.fit("    #{operation}#{arguments_suffix(arguments)}", width),
            TextLayout.fit("    A approve · D deny", width)
          ]

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

    Enum.map(rows, fn
      row when is_binary(row) -> TextLayout.fit(row, width)
      row -> row
    end)
  end

  defp arguments_suffix(arguments) when arguments in [nil, "", "%{}"], do: ""
  defp arguments_suffix(arguments), do: " · #{arguments}"

  defp role(:user), do: "YOU"
  defp role(:project), do: "PROJECT"
  defp role(:system), do: "SYSTEM"
  defp role(_role), do: "JIDO"

  defp title(state) do
    {width, _height} = state.size
    prefix = title_prefix(state.selection)
    {symbol, status, style} = header_status(state)
    suffix = " #{symbol} #{status} "
    suffix_width = DisplayWidth.string_width(suffix)

    if suffix_width >= width do
      TextLayout.fit("JIDO", width)
    else
      available = width - suffix_width
      {prefix, prefix_width} = DisplayWidth.truncate(prefix, available)
      divider = String.duplicate("─", max(available - prefix_width, 0))

      [
        {prefix, Style.new(attrs: [:bold])},
        {divider, Style.new(fg: :bright_black)},
        {suffix, style}
      ]
    end
  end

  defp title_prefix(nil), do: " JIDO "
  defp title_prefix(selection), do: " JIDO · #{Selection.label(selection)} "

  defp header_status(%State{activity: {:failed, :startup, _reason, _error}}),
    do: {"✗", "STARTUP FAILED", timeline_status_style(:failed)}

  defp header_status(%State{startup: :starting}),
    do: {"○", "STARTING", timeline_status_style(:running)}

  defp header_status(%State{activity: :idle}),
    do: {"●", "READY", timeline_status_style(:completed)}

  defp header_status(%State{activity: {:review, _, _, _, _}}),
    do: {"◆", "REVIEW", timeline_status_style(:review)}

  defp header_status(%State{activity: {:failed, _, _, _}}),
    do: {"✗", "FAILED", timeline_status_style(:failed)}

  defp header_status(%State{activity: {:cancelling, _, _}}),
    do: {"■", "CANCELLING", timeline_status_style(:cancelled)}

  defp header_status(%State{activity: {:active, _, _, _}}),
    do: {"●", "RUNNING", timeline_status_style(:running)}

  defp header_status(%State{activity: {:starting, _}}),
    do: {"○", "STARTING", timeline_status_style(:running)}

  defp header_status(_state), do: {"●", "READY", timeline_status_style(:completed)}

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

  defp status_row(%State{activity: {:failed, :startup, _reason, _error}}),
    do: "ERROR · Esc exit"

  defp status_row(%State{startup: :starting, activity: {:starting, {:turn, _turn}}}),
    do: "STARTING · prompt queued · Esc exit"

  defp status_row(%State{startup: :starting, activity: {:cancelling, _turn, :before_start}}),
    do: "STARTING · prompt cancelled · Esc exit"

  defp status_row(%State{startup: :starting}),
    do: "STARTING · Enter queue · Esc exit"

  defp status_row(%State{scroll_offset: offset}) when offset > 0,
    do: "HISTORY · #{offset} rows back · PgDn latest"

  defp status_row(%State{activity: :idle}),
    do: "INPUT · Enter send · Ctrl-J newline · Esc exit"

  defp status_row(%State{activity: {:starting, {:turn, _turn}}}),
    do: "WORK · starting turn · Ctrl-C cancel"

  defp status_row(%State{activity: {:active, _request, _turn, _phase}} = state) do
    queued =
      case state.session do
        %Jido.Console.Session.View{queue: []} -> ""
        %Jido.Console.Session.View{queue: queue} -> " · #{length(queue)} queued"
        _session -> ""
      end

    "INPUT · Enter queue#{queued} · Ctrl-J newline · Ctrl-C cancel"
  end

  defp status_row(%State{activity: {:cancelling, _turn, _target}}), do: "WORK · cancelling"

  defp status_row(%State{activity: {:review, _request, _turn, _result, :awaiting}}),
    do: "REVIEW · A approve · D deny · Ctrl-C cancel"

  defp status_row(%State{activity: {:review, _request, _turn, _result, {:responding, _decision}}}),
    do: "REVIEW · sending decision"

  defp status_row(%State{activity: {:failed, :hibernated, _reason, error}}),
    do: SafeText.summary(error)

  defp status_row(%State{activity: {:failed, _kind, _reason, error}}),
    do: "ERROR · #{SafeText.summary(error)}"

  defp status_row(%State{activity: activity}), do: Activity.tag(activity) |> Atom.to_string()
end
