defmodule Jido.Console.TestSupport.ClientParityBoundary do
  @moduledoc "Exact raw-path and proof-oracle guard for M2-E31."

  @raw_tokens [
    "{:jidoka,",
    "session_runtime_",
    "session_control_result",
    "Jidoka.Event",
    "Session.Server"
  ]

  @oracle_tokens ["Client.snapshot(", ".observe("]

  @spec raw_violations(String.t()) :: [String.t()]
  def raw_violations(source) when is_binary(source) do
    Enum.filter(@raw_tokens, &String.contains?(source, &1))
  end

  @spec oracle_violations(String.t()) :: [String.t()]
  def oracle_violations(source) when is_binary(source) do
    Enum.filter(@oracle_tokens, &String.contains?(source, &1))
  end
end
