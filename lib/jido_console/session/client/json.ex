defmodule Jido.Console.Session.Client.JSON do
  @moduledoc """
  JSON-compatible semantic projection of Session.Client.

  This module does not write automation standard output. That remains
  `Jido.Console.Automation.JSONL`.
  """

  @doc "Encodes one semantic event as JSON."
  @spec encode(map()) :: {:ok, String.t()} | {:error, term()}
  def encode(event) when is_map(event) do
    Jason.encode(sanitize(event))
  end

  @doc "Encodes an ordered event list."
  @spec encode_stream([map()]) :: {:ok, String.t()} | {:error, term()}
  def encode_stream(events) when is_list(events) do
    Jason.encode(Enum.map(events, &sanitize/1))
  end

  defp sanitize(value) when is_pid(value) or is_reference(value) or is_function(value), do: nil

  defp sanitize(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, sanitize(item)} end)
  end

  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)
  defp sanitize(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize(value), do: value
end
