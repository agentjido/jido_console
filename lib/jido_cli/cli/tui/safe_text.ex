defmodule Jido.Cli.Tui.SafeText do
  @moduledoc false

  @csi ~r/\x1B\[[0-?]*[ -\/]*[@-~]/u
  @osc ~r/\x1B\][^\x07]*(?:\x07|\x1B\\)/u
  @escape ~r/\x1B(?:.|$)/u
  @single_line_controls ~r/[\x00-\x1F\x7F-\x9F]+/u
  @multiline_controls ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]+/u
  @summary_limit 240

  @spec clean(term()) :: String.t()
  def clean(value) do
    value
    |> text()
    |> strip_sequences()
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(@multiline_controls, "")
  end

  @spec summary(term(), keyword()) :: String.t()
  def summary(value, opts \\ []) do
    limit = Keyword.get(opts, :limit, @summary_limit)

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
    |> String.replace(@osc, "")
    |> String.replace(@csi, "")
    |> String.replace(@escape, "")
  end
end
