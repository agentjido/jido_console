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
end
