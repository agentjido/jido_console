defmodule Jido.Console.Providers.ModelCheck do
  @moduledoc "Runs development provider checks against recorded contract evidence."

  alias Jido.Console.Models
  alias Jido.Console.Models.Commands
  alias Jido.Console.Policy.Preflight
  alias Jido.Console.Providers.{Harness, Redaction}

  @features ~w(streaming tools multi_turn_tools structured_results cancellation timeout prompt_cache)a

  @doc "Checks one model with recorded evidence or a preflight policy."
  @spec run(String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()}
          | {:error, {:offline_denied | :capability_denied | :contract_failed, String.t()}}
          | {:error, term()}
  def run(provider_or_identity, model \\ nil, opts \\ [])

  def run(identity, nil, opts) when is_binary(identity) do
    with {:ok, provider, model} <- Commands.parse_identity(identity) do
      run(provider, model, opts)
    end
  end

  def run(provider, model, opts) when is_binary(provider) and is_binary(model) do
    with {:ok, entry} <- Models.show(provider, model, opts) do
      cond do
        Keyword.get(opts, :offline, false) -> offline_check(entry, opts)
        required = Keyword.get(opts, :require) -> required_check(entry, List.wrap(required), opts)
        true -> recorded_check(entry, opts)
      end
    end
  end

  defp offline_check(entry, opts) do
    case Preflight.check(
           Keyword.merge(opts,
             provider: entry.provider,
             model: entry.model,
             entry: entry,
             offline: true,
             network: fn -> raise "offline check must not call the network" end,
             credentials: fn -> raise "offline check must not resolve credentials" end
           )
         ) do
      {:error, decision} -> {:error, {:offline_denied, format_decision("offline", entry, decision)}}
      {:ok, decision} -> {:ok, format_decision("offline", entry, decision)}
    end
  end

  defp required_check(entry, required, opts) do
    features = Enum.map(required, &feature_atom/1)

    if Enum.any?(features, &match?({:error, _reason}, &1)) do
      {:error, :invalid_required_feature}
    else
      required_features = Enum.map(features, fn {:ok, feature} -> feature end)

      case Preflight.check(
             Keyword.merge(opts,
               provider: entry.provider,
               model: entry.model,
               entry: entry,
               required_features: required_features
             )
           ) do
        {:ok, decision} ->
          recorded_check(entry, opts, format_decision("preflight", entry, decision))

        {:error, decision} ->
          {:error, {:capability_denied, format_decision("preflight", entry, decision)}}
      end
    end
  end

  defp recorded_check(entry, opts, prefix \\ "") do
    with {:ok, results} <- Harness.run(Keyword.put(opts, :entry, entry)) do
      output = prefix <> format_results(entry, results)
      failed? = Enum.any?(results, &(&1.status != :pass or &1.evidence_id != entry.evidence_id))

      if failed?, do: {:error, {:contract_failed, output}}, else: {:ok, output}
    end
  end

  defp format_results(entry, results) do
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
    case Enum.find(@features, &(Atom.to_string(&1) == feature)) do
      nil -> {:error, :invalid_required_feature}
      value -> {:ok, value}
    end
  end

  defp feature_atom(_feature), do: {:error, :invalid_required_feature}
end
