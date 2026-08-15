defmodule Jido.Console.Terminal.Frame do
  @moduledoc "Pure full-screen frame data and rendering helpers."

  alias Jido.Console.Terminal.PlainText

  @enforce_keys [:width, :height, :rows]
  defstruct [:width, :height, :rows, :cursor]

  @type cursor :: {pos_integer(), pos_integer()} | nil
  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          rows: [String.t()],
          cursor: cursor()
        }

  @doc "Builds a normalized frame."
  @spec new(pos_integer(), pos_integer(), [String.t()], keyword()) :: t()
  def new(width, height, rows, opts \\ [])
      when width > 0 and height > 0 and is_list(rows) do
    rows =
      rows
      |> Enum.take(height)
      |> Enum.map(&fit(&1, width))
      |> then(&(&1 ++ List.duplicate(String.duplicate(" ", width), height - length(&1))))

    %__MODULE__{
      width: width,
      height: height,
      rows: rows,
      cursor: normalize_cursor(Keyword.get(opts, :cursor), width, height)
    }
  end

  @doc "Converts a complete frame into ANSI output."
  @spec to_iodata(t()) :: iodata()
  def to_iodata(%__MODULE__{} = frame) do
    cursor =
      case frame.cursor do
        {column, row} -> ["\e[", Integer.to_string(row), ";", Integer.to_string(column), "H\e[?25h"]
        nil -> "\e[?25l"
      end

    [
      "\e[?25l\e[H",
      Enum.intersperse(frame.rows, "\e[K\r\n"),
      "\e[J",
      cursor
    ]
  end

  @doc "Fits text to one terminal row."
  @spec fit(iodata(), non_neg_integer()) :: String.t()
  def fit(_text, 0), do: ""

  def fit(text, width) when width > 0 do
    text =
      text
      |> IO.iodata_to_binary()
      |> PlainText.clean()
      |> String.replace(["\r", "\n"], " ")
      |> String.replace("\t", "    ")

    {content, content_width} = take_width(String.graphemes(text), width, [], 0)
    IO.iodata_to_binary([content, String.duplicate(" ", width - content_width)])
  end

  @doc "Wraps plain text to a terminal width."
  @spec wrap(String.t(), pos_integer()) :: [String.t()]
  def wrap(text, width) when is_binary(text) and width > 0 do
    text
    |> PlainText.clean()
    |> String.replace("\t", "    ")
    |> String.split("\n", trim: false)
    |> Enum.flat_map(&wrap_line(&1, width))
  end

  @doc "Returns the displayed terminal width of plain text."
  @spec width(String.t()) :: non_neg_integer()
  def width(text) when is_binary(text) do
    text = text |> PlainText.clean() |> String.replace(["\n", "\t"], "")
    :shell.prompt_width(text, :unicode)
  rescue
    _exception -> String.length(text)
  end

  defp wrap_line("", _width), do: [""]

  defp wrap_line(line, width) do
    line
    |> String.graphemes()
    |> Enum.reduce({[], "", 0}, fn grapheme, {lines, current, current_width} ->
      grapheme_width = width(grapheme)

      if current != "" and current_width + grapheme_width > width do
        {[current | lines], grapheme, grapheme_width}
      else
        {lines, current <> grapheme, current_width + grapheme_width}
      end
    end)
    |> then(fn {lines, current, _current_width} -> Enum.reverse([current | lines]) end)
  end

  defp take_width([], _limit, content, width), do: {Enum.reverse(content), width}

  defp take_width([grapheme | rest], limit, content, current_width) do
    grapheme_width = width(grapheme)

    if current_width + grapheme_width <= limit do
      take_width(rest, limit, [grapheme | content], current_width + grapheme_width)
    else
      {Enum.reverse(content), current_width}
    end
  end

  defp normalize_cursor(nil, _width, _height), do: nil

  defp normalize_cursor({column, row}, width, height) do
    {column |> max(1) |> min(width), row |> max(1) |> min(height)}
  end
end
