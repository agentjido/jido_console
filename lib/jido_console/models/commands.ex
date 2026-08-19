defmodule Jido.Console.Models.Commands do
  @moduledoc """
  Command-line model list and show operations.

  Output is stable, redacted, and limited to catalog records.
  """

  alias Jido.Console.Models
  alias Jido.Console.Providers.Redaction

  @doc "Lists declared catalog models."
  @spec list(keyword()) :: {:ok, String.t()} | {:error, term()}
  def list(opts \\ []) do
    with {:ok, entries} <- Models.list(opts) do
      {:ok, format_list(entries)}
    end
  end

  @doc "Shows one catalog model by provider and model identity."
  @spec show(String.t(), String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, term()}
  def show(provider_or_identity, model \\ nil, opts \\ [])

  def show(identity, nil, opts) when is_binary(identity) do
    with {:ok, provider, model} <- parse_identity(identity) do
      show(provider, model, opts)
    end
  end

  def show(provider, model, opts) when is_binary(provider) and is_binary(model) do
    with {:ok, entry} <- Models.show(provider, model, opts) do
      {:ok, format_show(entry)}
    end
  end

  @doc "Parses `provider:model` or a provider plus model pair."
  @spec parse_identity(String.t()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def parse_identity(identity) when is_binary(identity) do
    case String.split(identity, ":", parts: 2) do
      [provider, model] when provider != "" and model != "" -> {:ok, provider, model}
      _other -> {:error, :invalid_model_identity}
    end
  end

  defp format_list(entries) do
    header = "PROVIDER\tMODEL\tTIER\tEVIDENCE\n"

    rows =
      entries
      |> Enum.sort_by(& &1.identity)
      |> Enum.map_join("", fn entry ->
        "#{entry.provider}\t#{entry.model}\t#{entry.tier}\t#{entry.evidence_id}\n"
      end)

    header <> rows
  end

  defp format_show(entry) when is_map(entry) do
    capabilities =
      entry.capabilities
      |> Enum.sort_by(fn {key, _feature} -> key end)
      |> Enum.map_join("", fn {key, feature} ->
        "capability.#{key}: #{feature.state} #{feature.evidence || "none"}\n"
      end)

    gaps = Enum.map_join(entry.known_gaps, " | ", &Redaction.redact/1)
    metadata = Map.get(entry, :metadata, %{})
    lifecycle = value(metadata, :lifecycle, %{}) || %{}

    """
    identity: #{entry.identity}
    provider: #{entry.provider}
    model: #{entry.model}
    tier: #{entry.tier}
    evidence: #{entry.evidence_id}
    cost.class: #{entry.cost[:class] || entry.cost["class"]}
    cost.input_per_million: #{value(entry.cost, :input, "unknown")}
    cost.output_per_million: #{value(entry.cost, :output, "unknown")}
    limits.context_tokens: #{entry.limits[:context_tokens] || entry.limits["context_tokens"]}
    limits.output_tokens: #{entry.limits[:output_tokens] || entry.limits["output_tokens"]}
    metadata.source: #{value(metadata, :source, :unknown)}
    lifecycle.status: #{value(lifecycle, :status, "active")}
    lifecycle.replacement: #{value(lifecycle, :replacement, "none")}
    known_gaps: #{gaps}
    """ <> capabilities
  end

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
