defmodule Jido.Console.Terminal.PlainText do
  @moduledoc "Converts external values to terminal-safe plain text."

  @doc "Removes terminal sequences and unsafe controls while it keeps line breaks."
  @spec clean(term()) :: String.t()
  def clean(value) do
    value
    |> text()
    |> strip_sequences()
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(multiline_controls(), "")
    |> String.replace(bidirectional_controls(), "")
  end

  @doc "Returns terminal-safe text on one bounded line."
  @spec summary(term(), non_neg_integer()) :: String.t()
  def summary(value, limit) when is_integer(limit) and limit >= 0 do
    value
    |> text()
    |> strip_sequences()
    |> String.replace(single_line_controls(), " ")
    |> String.replace(bidirectional_controls(), "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, limit)
  end

  defp text(value) when is_binary(value) do
    if String.valid?(value), do: value, else: inspect(value, limit: 20, printable_limit: 240)
  end

  defp text(value), do: inspect(value, limit: 20, printable_limit: 240)

  defp strip_sequences(text) do
    text
    |> String.replace(control_strings(), "")
    |> String.replace(csi(), "")
    |> String.replace(escape(), "")
  end

  # Keep compiled regexes out of module attributes. OTP 28 Regex values hold a
  # reference that Elixir 1.18 cannot inject from an attribute into a function.
  defp control_strings, do: ~r/\x1B(?:\][^\x07\x1B]*(?:\x07|\x1B\\|$)|[P^_X].*?(?:\x1B\\|$))/su
  defp csi, do: ~r/\x1B\[[0-?]*[ -\/]*[@-~]/u
  defp escape, do: ~r/\x1B(?:.|$)/su
  defp multiline_controls, do: ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]+/u
  defp single_line_controls, do: ~r/[\x00-\x1F\x7F-\x9F]+/u
  defp bidirectional_controls, do: ~r/[\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u
end
