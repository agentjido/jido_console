defmodule Jido.Cli.Tui.Editor do
  @moduledoc "Pure one-line prompt editor."

  alias Jido.Cli.Terminal.Frame

  defstruct text: "", cursor: 0

  @type t :: %__MODULE__{text: String.t(), cursor: non_neg_integer()}

  @spec insert(t(), String.t()) :: t()
  def insert(%__MODULE__{} = editor, text) when is_binary(text) do
    text = String.replace(text, ~r/\R/u, " ")
    graphemes = String.graphemes(editor.text)
    {left, right} = Enum.split(graphemes, editor.cursor)
    new_text = Enum.join(left) <> text <> Enum.join(right)
    cursor = length(String.graphemes(Enum.join(left) <> text))
    %__MODULE__{text: new_text, cursor: cursor}
  end

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

  @spec clear(t()) :: t()
  def clear(%__MODULE__{}), do: %__MODULE__{}

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
end
