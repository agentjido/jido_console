defmodule Jido.Console.Terminal.TextLayout do
  @moduledoc false

  alias Jido.Console.Terminal.PlainText
  alias TermUI.{DisplayWidth, Frame}

  @max_render_bytes 512_000

  @doc "Fits safe plain text to one terminal row."
  @spec fit(iodata(), non_neg_integer()) :: String.t()
  def fit(_text, 0), do: ""

  def fit(text, width) when width > 0 do
    text =
      text
      |> IO.iodata_to_binary()
      |> PlainText.clean()
      |> String.replace(["\r", "\n"], " ")
      |> String.replace("\t", "    ")

    Frame.fit(text, width)
  end

  @doc "Wraps safe plain text to a terminal width."
  @spec wrap(String.t(), pos_integer()) :: [String.t()]
  def wrap(text, width) when is_binary(text) and width > 0 do
    text
    |> PlainText.clean()
    |> String.replace("\t", "    ")
    |> Frame.wrap(width)
  end

  @doc "Wraps only a bounded tail of text and returns at most `max_rows` rows."
  @spec wrap_tail(String.t(), pos_integer(), non_neg_integer()) :: [String.t()]
  def wrap_tail(_text, _width, 0), do: []

  def wrap_tail(text, width, max_rows)
      when is_binary(text) and width > 0 and max_rows > 0 do
    byte_limit = min(@max_render_bytes, max(max_rows * width * 4, max_rows * 4))

    text
    |> retain_tail(byte_limit)
    |> wrap(width)
    |> Enum.take(-max_rows)
  end

  @doc false
  @spec retain_tail(String.t(), pos_integer()) :: String.t()
  def retain_tail(text, byte_limit) when is_binary(text) and byte_limit > 0 do
    text
    |> binary_tail(byte_limit)
    |> PlainText.clean()
    |> String.replace("\t", "    ")
  end

  @doc "Returns safe plain text display width."
  @spec width(String.t()) :: non_neg_integer()
  def width(text) when is_binary(text) do
    text = text |> PlainText.clean() |> String.replace(["\n", "\t"], "")
    DisplayWidth.string_width(text)
  end

  defp binary_tail(text, limit) when byte_size(text) <= limit, do: text

  defp binary_tail(text, limit) do
    start = byte_size(text) - limit
    text |> binary_part(start, limit) |> valid_tail(0)
  end

  defp valid_tail(<<>>, _attempts), do: ""
  defp valid_tail(text, attempts) when attempts >= 4, do: PlainText.clean(text)

  defp valid_tail(text, attempts) do
    if String.valid?(text) do
      text
    else
      text |> binary_part(1, byte_size(text) - 1) |> valid_tail(attempts + 1)
    end
  end
end
