defmodule Jido.Console.Terminal.PlainText do
  @moduledoc "Converts external values to terminal-safe plain text."

  @control_strings ~r/\x1B(?:\][^\x07\x1B]*(?:\x07|\x1B\\|$)|[P^_X].*?(?:\x1B\\|$))/su
  @csi ~r/\x1B\[[0-?]*[ -\/]*[@-~]/u
  @escape ~r/\x1B(?:.|$)/su
  @multiline_controls ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]+/u
  @single_line_controls ~r/[\x00-\x1F\x7F-\x9F]+/u

  @doc "Removes terminal sequences and unsafe controls while it keeps line breaks."
  @spec clean(term()) :: String.t()
  def clean(value) do
    value
    |> text()
    |> strip_sequences()
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(@multiline_controls, "")
  end

  @doc "Returns terminal-safe text on one bounded line."
  @spec summary(term(), non_neg_integer()) :: String.t()
  def summary(value, limit) when is_integer(limit) and limit >= 0 do
    value
    |> text()
    |> strip_sequences()
    |> String.replace(@single_line_controls, " ")
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
    |> String.replace(@control_strings, "")
    |> String.replace(@csi, "")
    |> String.replace(@escape, "")
  end
end
