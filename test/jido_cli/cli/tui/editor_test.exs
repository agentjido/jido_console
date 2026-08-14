defmodule Jido.Cli.Tui.EditorTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Tui.Editor

  test "edits by grapheme instead of byte" do
    editor = %Editor{} |> Editor.insert("a😀b") |> Editor.left() |> Editor.backspace()
    assert editor.text == "ab"
    assert editor.cursor == 1
  end

  test "inserts and edits multiline text" do
    editor = %Editor{} |> Editor.insert("one") |> Editor.newline() |> Editor.insert("two")
    assert editor.text == "one\ntwo"
    assert editor |> Editor.up() |> Map.fetch!(:cursor) == 3
    assert editor |> Editor.up() |> Editor.down() == editor
  end

  test "keeps the cursor visible in a narrow prompt" do
    editor = Editor.insert(%Editor{}, "123456")
    assert Editor.visible(editor, 4) == {"3456", 4}
  end

  test "keeps a Unicode cursor visible in a multiline viewport" do
    editor = Editor.from_text("one\n界界界")
    assert Editor.render(editor, 4, 2) == {["界界", "界"], {2, 1}}
  end

  test "removes pasted terminal controls without removing line breaks" do
    editor = Editor.insert(%Editor{}, "one\e[2J\n\e]0;title\atwo\x00")
    assert editor.text == "one\ntwo"
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
