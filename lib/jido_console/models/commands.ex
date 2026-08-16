defmodule Jido.Console.Models.Commands do
  @moduledoc """
  Command-line model list, show, and recorded contract test.

  Output is stable, redacted, and limited to catalog and harness records.
  """

  alias Jido.Console.Models
  alias Jido.Console.Policy.Preflight
  alias Jido.Console.Providers.{Harness, Redaction}

  @features ~w(streaming tools multi_turn_tools structured_results cancellation timeout prompt_cache)a

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

  @doc "Runs the recorded contract test or a preflight denial."
  @spec test(String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()}
          | {:error, {:offline_denied | :capability_denied | :contract_failed, String.t()}}
          | {:error, term()}
  def test(provider_or_identity, model \\ nil, opts \\ [])

  def test(identity, nil, opts) when is_binary(identity) do
    with {:ok, provider, model} <- parse_identity(identity) do
      test(provider, model, opts)
    end
  end

  def test(provider, model, opts) when is_binary(provider) and is_binary(model) do
    with {:ok, entry} <- Models.show(provider, model, opts) do
      cond do
        Keyword.get(opts, :offline, false) ->
          offline_test(entry, opts)

        required = Keyword.get(opts, :require) ->
          required_test(entry, List.wrap(required), opts)

        true ->
          recorded_test(entry, opts)
      end
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

  defp offline_test(entry, opts) do
    case Preflight.check(
           Keyword.merge(opts,
             provider: entry.provider,
             model: entry.model,
             entry: entry,
             offline: true,
             network: fn -> raise "models test offline must not call the network" end,
             credentials: fn -> raise "models test offline must not resolve credentials" end
           )
         ) do
      {:error, decision} ->
        {:error, {:offline_denied, format_decision("offline", entry, decision)}}

      {:ok, decision} ->
        {:ok, format_decision("offline", entry, decision)}
    end
  end

  defp required_test(entry, required, opts) do
    features = Enum.map(required, &feature_atom/1)

    if Enum.any?(features, &match?({:error, _}, &1)) do
      {:error, :invalid_required_feature}
    else
      features = Enum.map(features, fn {:ok, feature} -> feature end)

      case Preflight.check(
             Keyword.merge(opts,
               provider: entry.provider,
               model: entry.model,
               entry: entry,
               required_features: features
             )
           ) do
        {:ok, decision} ->
          recorded_test(entry, opts, format_decision("preflight", entry, decision))

        {:error, decision} ->
          {:error, {:capability_denied, format_decision("preflight", entry, decision)}}
      end
    end
  end

  defp recorded_test(entry, opts, prefix \\ "") do
    with {:ok, results} <- Harness.run(Keyword.put(opts, :entry, entry)) do
      output = prefix <> format_test(entry, results)
      failed? = Enum.any?(results, &(&1.status != :pass or &1.evidence_id != entry.evidence_id))

      if failed?, do: {:error, {:contract_failed, output}}, else: {:ok, output}
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

  defp format_test(entry, results) do
    rows =
      results
      |> Enum.sort_by(& &1.dimension)
      |> Enum.map_join("", fn result ->
        "contract.#{result.dimension}: #{result.status} #{Redaction.redact(result.reason)} " <>
          "evidence=#{result.evidence_id} test=#{result.test_id}\n"
      end)

    "identity: #{entry.identity}\nsource: recorded\n" <> rows
  end

  defp format_decision(kind, entry, decision) do
    "identity: #{entry.identity}\n#{kind}: #{decision.outcome}\nreason: #{Redaction.redact(decision.reason)}\n"
  end

  defp feature_atom(feature) when feature in @features, do: {:ok, feature}

  defp feature_atom(feature) when is_binary(feature) do
    allowed = Enum.map(@features, &Atom.to_string/1)

    if feature in allowed do
      {:ok, String.to_existing_atom(feature)}
    else
      {:error, :invalid_required_feature}
    end
  end

  defp feature_atom(_feature), do: {:error, :invalid_required_feature}
end
