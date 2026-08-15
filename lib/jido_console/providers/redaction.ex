defmodule Jido.Console.Providers.Redaction do
  @moduledoc "Removes credentials, private paths, and provider secrets from harness reports."

  @secret_patterns [
    ~r/sk-[A-Za-z0-9_\-]{8,}/,
    ~r/(?i)(api[_-]?key|authorization|bearer|token|secret)[=:\s]+\S+/,
    ~r/\/(?:Users|home)\/[^\/\s]+/
  ]

  @doc "Redacts sensitive strings in harness result reasons."
  @spec redact_results([map()]) :: [map()]
  def redact_results(results) when is_list(results) do
    Enum.map(results, fn result ->
      Map.update!(result, :reason, &redact/1)
    end)
  end

  @doc "Redacts one report string."
  @spec redact(String.t()) :: String.t()
  def redact(value) when is_binary(value) do
    Enum.reduce(@secret_patterns, value, fn pattern, acc ->
      Regex.replace(pattern, acc, "[redacted]")
    end)
  end
end
