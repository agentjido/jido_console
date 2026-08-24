defmodule Jido.Console.Tui.EditorTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.Editor
  alias TermUI.{Event, Selection}

  test "edits by grapheme instead of byte" do
    editor = Editor.new() |> Editor.insert("a😀b") |> Editor.left() |> Editor.backspace()
    assert Editor.value(editor) == "ab"
    assert editor.cursor == 1
  end

  test "inserts and edits multiline text" do
    editor = Editor.new() |> Editor.insert("one") |> Editor.newline() |> Editor.insert("two")
    assert Editor.value(editor) == "one\ntwo"
    assert editor |> Editor.up() |> Map.fetch!(:cursor) == 3
    assert editor |> Editor.up() |> Editor.down() == editor
  end

  test "keeps a Unicode cursor visible in a multiline viewport" do
    editor = Editor.from_text("one\n界界界")
    frame = Editor.frame(editor, 4, 2)
    assert Enum.map(1..2, &(frame |> TermUI.Frame.row_text(&1) |> String.trim_trailing())) == ["界界", "界"]
    assert frame.cursor == {3, 2}
  end

  test "puts an exact-width end cursor on a new visual row" do
    editor = Editor.from_text("1234")
    assert Editor.frame(editor, 4, 2).cursor == {1, 2}
  end

  test "removes pasted terminal controls without removing line breaks" do
    editor = Editor.insert(Editor.new(), "one\e[2J\n\e]0;title\atwo\x00")
    assert Editor.value(editor) == "one\ntwo"
  end

  test "does not move or delete beyond the editor boundaries" do
    empty = Editor.new()
    assert Editor.left(empty) == empty
    assert Editor.backspace(empty) == empty

    editor = Editor.insert(empty, "a")
    assert Editor.right(editor) == editor
    assert Editor.clear(editor) == empty
  end

  test "replaces the full sanitized value and moves the grapheme cursor to the end" do
    editor = Editor.from_text("old value") |> Editor.left()
    editor = Editor.replace(editor, " /model openai:gpt-4.1-mini\e[2J")

    assert Editor.value(editor) == " /model openai:gpt-4.1-mini"
    assert Editor.cursor(editor) == String.length(" /model openai:gpt-4.1-mini")
  end

  test "reports the TextArea grapheme cursor" do
    editor = Editor.from_text("a😀b") |> Editor.left()
    assert Editor.cursor(editor) == 2
  end

  test "keeps mention and escaped-at syntax as ordinary editable text" do
    editor = Editor.new() |> Editor.insert("Review @lib/value.ex and \\@literal") |> Editor.left() |> Editor.right()
    assert Editor.value(editor) == "Review @lib/value.ex and \\@literal"
  end

  test "delegates Unicode selection and copy to TermUI TextArea" do
    editor = Editor.from_text("one\ntwo")
    {editor, []} = Editor.update(editor, Event.key(:left, modifiers: [:shift]))
    {editor, []} = Editor.update(editor, Event.key(:left, modifiers: [:shift]))

    assert Selection.extract(editor.selection, Editor.value(editor)) == "wo"
    assert {^editor, [{:copy, "wo"}]} = Editor.update(editor, Event.key("c", modifiers: [:ctrl]))
  end
end
