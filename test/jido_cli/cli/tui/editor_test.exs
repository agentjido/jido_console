defmodule Jido.Cli.Tui.EditorTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Tui.Editor

  test "edits by grapheme instead of byte" do
    editor = %Editor{} |> Editor.insert("a😀b") |> Editor.left() |> Editor.backspace()
    assert editor.text == "ab"
    assert editor.cursor == 1
  end

  test "converts pasted newlines to spaces" do
    assert %Editor{} |> Editor.insert("one\ntwo") |> Map.fetch!(:text) == "one two"
  end

  test "keeps the cursor visible in a narrow prompt" do
    editor = Editor.insert(%Editor{}, "123456")
    assert Editor.visible(editor, 4) == {"3456", 4}
  end

  test "does not move or delete beyond the editor boundaries" do
    empty = %Editor{}
    assert Editor.left(empty) == empty
    assert Editor.backspace(empty) == empty

    editor = Editor.insert(empty, "a")
    assert Editor.right(editor) == editor
    assert Editor.clear(editor) == empty
  end

  test "keeps mention and escaped-at syntax as ordinary editable text" do
    editor = %Editor{} |> Editor.insert("Review @lib/value.ex and \\@literal") |> Editor.left() |> Editor.right()
    assert editor.text == "Review @lib/value.ex and \\@literal"
  end
end
