defmodule Jido.Console.Terminal.Frame do
  @moduledoc "Pure full-screen frame data and rendering helpers."

  alias Jido.Console.Terminal.PlainText
  alias TermUI.Renderer.DisplayWidth

  @schema Zoi.struct(
            __MODULE__,
            %{
              width: Zoi.integer() |> Zoi.positive(),
              height: Zoi.integer() |> Zoi.positive(),
              rows: Zoi.array(Zoi.string()),
              cursor:
                Zoi.tuple({Zoi.integer() |> Zoi.positive(), Zoi.integer() |> Zoi.positive()})
                |> Zoi.nullish()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

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

    {content, _content_width} = DisplayWidth.truncate(text, width)
    DisplayWidth.pad(content, width)
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
    DisplayWidth.string_width(text)
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

  defp normalize_cursor(nil, _width, _height), do: nil

  defp normalize_cursor({column, row}, width, height) do
    {column |> max(1) |> min(width), row |> max(1) |> min(height)}
  end
end
