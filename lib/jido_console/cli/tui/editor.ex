defmodule Jido.Console.Tui.Editor do
  @moduledoc false

  alias Jido.Console.Terminal.PlainText
  alias TermUI.{Event, Frame, Selection}
  alias TermUI.Widget.TextArea

  @max_graphemes 65_536

  @type t :: TextArea.t()

  @spec new() :: t()
  def new, do: TextArea.init(max_length: @max_graphemes)

  @spec insert(t(), String.t()) :: t()
  def insert(%TextArea{} = editor, text) when is_binary(text) do
    {editor, _messages} = update(editor, Event.paste(text))
    editor
  end

  @spec newline(t()) :: t()
  def newline(%TextArea{} = editor) do
    {editor, _messages} = update(editor, Event.key(:enter))
    editor
  end

  @spec backspace(t()) :: t()
  def backspace(%TextArea{} = editor), do: key(editor, :backspace)

  @spec left(t()) :: t()
  def left(%TextArea{} = editor), do: key(editor, :left)

  @spec right(t()) :: t()
  def right(%TextArea{} = editor), do: key(editor, :right)

  @spec up(t()) :: t()
  def up(%TextArea{} = editor), do: key(editor, :up)

  @spec down(t()) :: t()
  def down(%TextArea{} = editor), do: key(editor, :down)

  @spec clear(t()) :: t()
  def clear(%TextArea{} = editor), do: TextArea.set_value(editor, "")

  @spec replace(t(), String.t()) :: t()
  def replace(%TextArea{} = editor, text) when is_binary(text),
    do: TextArea.set_value(editor, sanitize(text))

  @spec from_text(String.t()) :: t()
  def from_text(text) when is_binary(text) do
    TextArea.init(value: sanitize(text), max_length: @max_graphemes)
  end

  @spec value(t()) :: String.t()
  def value(%TextArea{} = editor), do: TextArea.value(editor)

  @spec cursor(t()) :: non_neg_integer()
  def cursor(%TextArea{} = editor), do: editor.cursor

  @spec selection?(t()) :: boolean()
  def selection?(%TextArea{} = editor), do: not Selection.empty?(editor.selection)

  @spec update(t(), Event.t()) :: {t(), [term()]}
  def update(%TextArea{} = editor, %Event.Text{text: text} = event) do
    case sanitize(text) do
      "" -> {editor, []}
      text -> TextArea.update(%{event | text: text}, editor)
    end
  end

  def update(%TextArea{} = editor, %Event.Paste{content: text} = event),
    do: TextArea.update(%{event | content: sanitize(text)}, editor)

  def update(%TextArea{} = editor, event), do: TextArea.update(event, editor)

  @spec mouse(t(), Event.Mouse.t(), {pos_integer(), pos_integer()}) :: {t(), [term()]}
  def mouse(%TextArea{} = editor, %Event.Mouse{} = event, dimensions),
    do: TextArea.mouse(event, editor, dimensions)

  @spec frame(t(), pos_integer(), pos_integer()) :: Frame.t()
  def frame(%TextArea{} = editor, width, max_rows) when width > 0 and max_rows > 0 do
    TextArea.view(editor, {width, max_rows})
  end

  defp key(editor, name) do
    {editor, _messages} = update(editor, Event.key(name))
    editor
  end

  defp sanitize(text) do
    text
    |> PlainText.clean()
    |> String.replace("\t", "    ")
    |> String.graphemes()
    |> Enum.take(@max_graphemes)
    |> Enum.join()
  end
end
