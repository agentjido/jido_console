defmodule Jido.Console.Tui.ViewTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.{App, Editor, State, Turn, View}
  alias TermUI.Frame

  test "returns the canonical frame for normal and tiny terminals" do
    state = State.new(nil, {40, 10})

    assert %Frame{width: 40, height: 10} = View.render(state)
    assert %Frame{width: 40, height: 10} = App.view(%{tui: state})
    assert %Frame{width: 1, height: 1} = View.render(%{state | size: {1, 1}})
  end

  test "limits oversized terminal dimensions to TermUI frame limits" do
    frame = View.render(State.new(nil, {1_001, 501}))

    assert %Frame{width: 1_000, height: 500} = frame
  end

  test "shows useful first-run context before the first turn" do
    state =
      State.new(nil, {80, 16},
        project_root: "/work/jido_console",
        model: "openai:gpt-4.1-mini",
        coding_profile: "coding.restricted",
        catalog_entries: [
          %{identity: "openai:gpt-4.1-mini", provider: "openai", model: "gpt-4.1-mini", tier: :supported}
        ]
      )

    text = state |> View.render() |> frame_text()

    assert text =~ "Jido is ready"
    assert text =~ "Model     openai:gpt-4.1-mini (supported)"
    assert text =~ "Profile   coding.restricted"
    assert text =~ "Workspace /work/jido_console"
    assert text =~ "Type a task below and press Enter."
    assert text =~ "Try: Explain this project"
  end

  test "explains that input is available during startup" do
    state = State.new(nil, {72, 14}, startup: :starting, project_root: "/work/project")
    text = state |> View.render() |> frame_text()

    assert text =~ "Starting Jido"
    assert text =~ "You can type now. Enter queues the task while Jido starts."
  end

  test "replaces the welcome with a clear startup failure" do
    state = %{
      State.new(nil, {72, 14})
      | activity: {:failed, :startup, :busy, "Another Jido process is using this database."}
    }

    text = state |> View.render() |> frame_text()

    assert text =~ "Jido could not start"
    assert text =~ "Another Jido process is using this database."
    assert text =~ "Fix the error above, then start Jido again."
    assert text =~ "Press Esc to exit."
    refute text =~ "Jido is ready"
  end

  test "does not show the welcome after transcript content exists" do
    state = %{State.new(nil, {40, 12}) | messages: [%{role: :assistant, content: "Existing session"}]}
    text = state |> View.render() |> frame_text()

    assert text =~ "Existing session"
    refute text =~ "Jido is ready"
  end

  test "renders client-local command feedback without transcript messages" do
    state = %{State.new(nil, {60, 12}) | command_notices: ["Models:\nopenai:gpt-4.1-mini supported current"]}
    text = state |> View.render() |> frame_text()

    assert text =~ "COMMAND"
    assert text =~ "openai:gpt-4.1-mini supported current"
    assert state.messages == []
  end

  test "places a short transcript below the title instead of above the prompt" do
    state = %{State.new(nil, {40, 16}) | messages: [%{role: :assistant, content: "Short answer"}]}
    frame = View.render(state)

    assert Frame.row_text(frame, 2) =~ "JIDO"
    assert Frame.row_text(frame, 3) =~ "Short answer"
  end

  test "keeps a multiline Unicode editor cursor inside the frame" do
    editor = Editor.from_text("alpha\n界e\u0301")
    frame = View.render(%{State.new(nil, {18, 8}) | editor: editor})

    assert {column, row} = frame.cursor
    assert column in 1..frame.width
    assert row in 1..frame.height
    assert Enum.any?(1..frame.height, &(Frame.row_text(frame, &1) =~ "界e\u0301"))
  end

  test "keeps TextArea selection styling in the composed frame" do
    editor = Editor.from_text("hello")
    {editor, []} = Editor.update(editor, TermUI.Event.key(:left, modifiers: [:shift]))
    {editor, []} = Editor.update(editor, TermUI.Event.key(:left, modifiers: [:shift]))
    frame = View.render(%{State.new(nil, {20, 8}) | editor: editor})

    assert Enum.any?(frame.cells, fn {_position, cell} -> :reverse in cell.attrs end)
  end

  test "renders assistant Markdown through MDEx" do
    state = %{
      State.new(nil, {40, 14})
      | messages: [%{role: :assistant, content: "# Heading\n\n**bold** text"}]
    }

    frame = View.render(state)
    text = Enum.map_join(1..frame.height, "\n", &Frame.row_text(frame, &1))

    assert text =~ "Heading"
    assert Enum.any?(frame.cells, fn {_position, cell} -> cell.char == "H" and :bold in cell.attrs end)
  end

  test "renders the supervised timeline with accessible operation states" do
    request = %{queue_item_id: "item-1", request_id: "request-1"}

    turn =
      0
      |> Turn.new("Inspect the project")
      |> Turn.put_request(request)
      |> Turn.apply_stream([
        tool_projection(0, "effect-running", "coding.read", "effect_started"),
        tool_projection(1, "effect-failed", "coding.search", "effect_failed"),
        %{
          request_id: "request-1",
          seq: 2,
          event: "llm_delta",
          terminal?: false,
          effect_kind: "llm",
          data: %{"chunk_type" => "content", "delta" => "I found one problem."}
        }
      ])

    state = %{State.new(nil, {80, 20}) | activity: {:active, request, turn, :streaming}}
    frame = View.render(state)
    text = frame_text(frame)

    assert text =~ "YOU"
    assert text =~ "Inspect the project"
    assert text =~ "JIDO"
    assert text =~ "├─ ● RUNNING  coding.read"
    assert text =~ "└─ ✗ FAILED  coding.search"
    assert text =~ "I found one problem."
    assert text =~ "● RUNNING"
    assert text =~ "INPUT · Enter queue"
    refute text =~ "must-not-render"

    assert Enum.any?(frame.cells, fn {_position, cell} -> cell.char == "●" and cell.fg == :cyan end)
    assert Enum.any?(frame.cells, fn {_position, cell} -> cell.char == "✗" and cell.fg == :red end)
  end

  test "shows an unfinished operation as cancelled when its turn is cancelled" do
    turn =
      0
      |> Turn.new("Stop the inspection")
      |> Turn.put_request(%{request_id: "request-1"})
      |> Turn.apply_stream([tool_projection(0, "effect-running", "coding.read", "effect_started")])
      |> Turn.finish(:cancelled, nil)

    state = %{State.new(nil, {80, 14}) | turns: [turn]}
    frame = View.render(state)
    text = frame_text(frame)

    assert text =~ "■ CANCELLED  coding.read"
    assert Enum.any?(frame.cells, fn {_position, cell} -> cell.char == "■" and cell.fg == :yellow end)
  end

  test "renders the retained git patch through DiffViewer instead of four plain lines" do
    patch =
      "--- a/file\n+++ b/file\n@@ -1,4 +1,4 @@\n one\n-two\n+changed\n three\n seventh-line"

    review = %{
      "kind" => "git_diff",
      "status" => "changed",
      "files" => [%{"path" => "file", "additions" => 1, "deletions" => 1}],
      "patch" => patch,
      "binary" => false,
      "truncated" => false
    }

    frame = View.render(%{State.new(nil, {60, 30}) | coding_reviews: [review]})
    text = Enum.map_join(1..frame.height, "\n", &Frame.row_text(frame, &1))

    assert text =~ "seventh-line"
    assert Enum.any?(frame.cells, fn {_position, cell} -> cell.char == "+" and cell.fg == :green end)
  end

  test "does not render patches from hidden coding reviews" do
    visible_review = %{"kind" => "edit", "status" => "changed", "path" => "visible"}

    hidden_review = %{
      "kind" => "git_diff",
      "status" => "changed",
      "files" => nil,
      "patch" => "this patch must remain hidden",
      "binary" => false,
      "truncated" => false
    }

    frame = View.render(%{State.new(nil, {40, 6}) | coding_reviews: [visible_review, hidden_review]})
    text = Enum.map_join(1..frame.height, "\n", &Frame.row_text(frame, &1))

    assert text =~ "review truncated"
  end

  test "limits the visible rows of a git patch" do
    patch = Enum.map_join(1..100, "\n", &"+changed line #{&1}")

    review = %{
      "kind" => "git_diff",
      "status" => "changed",
      "files" => [],
      "patch" => patch,
      "binary" => false,
      "truncated" => false
    }

    frame = View.render(%{State.new(nil, {40, 8}) | coding_reviews: [review]})
    text = Enum.map_join(1..frame.height, "\n", &Frame.row_text(frame, &1))

    assert text =~ "review truncated"
    refute text =~ "changed line 100"
  end

  test "a large retained transcript has bounded frame and render work" do
    content = String.duplicate("output line\n", 20_000)
    turn = 1 |> Turn.new("prompt") |> Turn.finish(:completed, content)
    state = %{State.new(nil, {80, 24}) | turns: List.duplicate(turn, 100)}

    assert %Frame{width: 80, height: 24} = frame = View.render(state)
    assert map_size(frame.cells) <= 80 * 24
    assert Enum.any?(1..frame.height, &(Frame.row_text(frame, &1) =~ "output line"))

    scrolled = View.render(%{state | scroll_offset: 1_000_000})
    assert %Frame{width: 80, height: 24} = scrolled
    assert map_size(scrolled.cells) <= 80 * 24
  end

  defp frame_text(frame) do
    Enum.map_join(1..frame.height, "\n", &Frame.row_text(frame, &1))
  end

  defp tool_projection(sequence, effect_id, operation, event) do
    %{
      request_id: "request-1",
      seq: sequence,
      event: event,
      terminal?: false,
      effect_id: effect_id,
      effect_kind: "operation",
      operation: operation,
      loop_index: 0,
      status: if(event == "effect_failed", do: "failed", else: "started"),
      data: %{"result" => "must-not-render"}
    }
  end
end
