defmodule Jido.Console.Tui.Editor do
  @moduledoc "Pure multiline prompt editor."

  alias Jido.Console.Terminal.Frame
  alias Jido.Console.Terminal.PlainText

  @max_graphemes 65_536

  defstruct text: "", cursor: 0

  @type t :: %__MODULE__{text: String.t(), cursor: non_neg_integer()}

  @spec insert(t(), String.t()) :: t()
  def insert(%__MODULE__{} = editor, text) when is_binary(text) do
    text = text |> PlainText.clean() |> String.replace("\t", "    ")
    graphemes = String.graphemes(editor.text)
    {left, right} = Enum.split(graphemes, editor.cursor)
    inserted = String.graphemes(text)
    graphemes = Enum.take(left ++ inserted ++ right, @max_graphemes)
    new_text = Enum.join(graphemes)
    cursor = min(length(left) + length(inserted), length(graphemes))
    %__MODULE__{text: new_text, cursor: cursor}
  end

  @spec newline(t()) :: t()
  def newline(%__MODULE__{} = editor), do: insert(editor, "\n")

  @spec backspace(t()) :: t()
  def backspace(%__MODULE__{cursor: 0} = editor), do: editor

  def backspace(%__MODULE__{} = editor) do
    graphemes = String.graphemes(editor.text)
    {left, right} = Enum.split(graphemes, editor.cursor)
    left = Enum.drop(left, -1)
    %__MODULE__{text: Enum.join(left ++ right), cursor: length(left)}
  end

  @spec left(t()) :: t()
  def left(%__MODULE__{} = editor), do: %{editor | cursor: max(editor.cursor - 1, 0)}

  @spec right(t()) :: t()
  def right(%__MODULE__{} = editor) do
    %{editor | cursor: min(editor.cursor + 1, length(String.graphemes(editor.text)))}
  end

  @spec up(t()) :: t()
  def up(%__MODULE__{} = editor), do: move_line(editor, -1)

  @spec down(t()) :: t()
  def down(%__MODULE__{} = editor), do: move_line(editor, 1)

  @spec clear(t()) :: t()
  def clear(%__MODULE__{}), do: %__MODULE__{}

  @spec from_text(String.t()) :: t()
  def from_text(text) when is_binary(text), do: insert(%__MODULE__{}, text)

  @doc "Returns a row viewport and a zero-based cursor position within it."
  @spec render(t(), pos_integer(), pos_integer()) :: {[String.t()], {non_neg_integer(), non_neg_integer()}}
  def render(%__MODULE__{} = editor, width, max_rows) when width > 0 and max_rows > 0 do
    rows = Frame.wrap(editor.text, width)
    {cursor_column, cursor_row} = cursor_position(editor, width)
    start = max(cursor_row - max_rows + 1, 0)
    visible = rows |> Enum.slice(start, max_rows) |> nonempty_rows()
    {visible, {min(cursor_column, width), cursor_row - start}}
  end

  @doc "Returns visible prompt text and its zero-based cursor column."
  @spec visible(t(), pos_integer()) :: {String.t(), non_neg_integer()}
  def visible(%__MODULE__{} = editor, width) when width > 0 do
    {left, right} = editor.text |> String.graphemes() |> Enum.split(editor.cursor)
    visible_left = take_from_end(left, width)
    left_width = Frame.width(Enum.join(visible_left))
    visible_right = take_from_start(right, width - left_width)
    {Enum.join(visible_left ++ visible_right), left_width}
  end

  defp take_from_end(graphemes, width) do
    graphemes
    |> Enum.reverse()
    |> take_from_start(width)
    |> Enum.reverse()
  end

  defp take_from_start(graphemes, width) do
    graphemes
    |> Enum.reduce_while({[], 0}, fn grapheme, {result, used} ->
      grapheme_width = Frame.width(grapheme)

      if used + grapheme_width <= width do
        {:cont, {[grapheme | result], used + grapheme_width}}
      else
        {:halt, {result, used}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp move_line(%__MODULE__{} = editor, direction) do
    lines = line_ranges(editor.text)
    current = Enum.find_index(lines, fn {start, length} -> editor.cursor <= start + length end)
    current = current || max(length(lines) - 1, 0)
    {start, length} = Enum.at(lines, current)
    column = min(editor.cursor - start, length)
    target = current + direction

    case Enum.at(lines, target) do
      {target_start, target_length} -> %{editor | cursor: target_start + min(column, target_length)}
      nil -> editor
    end
  end

  defp line_ranges(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.map(&length(String.graphemes(&1)))
    |> Enum.map_reduce(0, fn length, start -> {{start, length}, start + length + 1} end)
    |> elem(0)
  end

  defp cursor_position(editor, width) do
    editor.text
    |> String.graphemes()
    |> Enum.take(editor.cursor)
    |> Enum.reduce({0, 0}, fn
      "\n", {_column, row} ->
        {0, row + 1}

      grapheme, {column, row} ->
        grapheme_width = Frame.width(grapheme)

        if column > 0 and column + grapheme_width > width do
          {grapheme_width, row + 1}
        else
          {column + grapheme_width, row}
        end
    end)
  end

  defp nonempty_rows([]), do: [""]
  defp nonempty_rows(rows), do: rows
end
