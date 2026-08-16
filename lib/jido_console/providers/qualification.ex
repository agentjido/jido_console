defmodule Jido.Console.Providers.Qualification do
  @moduledoc """
  Builds a redacted provider qualification matrix from recorded contracts.

  A model stays out of the supported tier when any claimed capability is
  missing, failed, or blocked. Credential values never appear in the report.
  """

  alias Jido.Console.Auth
  alias Jido.Console.Models
  alias Jido.Console.Models.Catalog
  alias Jido.Console.Policy.Preflight
  alias Jido.Console.Providers.{Harness, Redaction}

  @extra_dimensions [:usage, :cost, :error_normalization]

  @type model_report :: map()
  @type report :: %{
          required(:provider) => String.t(),
          required(:models) => [model_report()],
          required(:credentials) => map(),
          required(:contract_version) => String.t()
        }

  @doc "Qualifies every catalog model for one provider."
  @spec run(String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def run(provider, opts \\ []) when is_binary(provider) do
    with {:ok, entries} <- provider_entries(provider, opts),
         {:ok, credentials} <- credential_record(provider, opts),
         {:ok, models} <- qualify_models(entries, opts) do
      {:ok,
       %{
         provider: provider,
         contract_version: Harness.contract_version(),
         credentials: credentials,
         models: models
       }}
    end
  end

  @doc "Encodes a redacted qualification report."
  @spec report(report()) :: map()
  def report(result) do
    %{
      "schema" => "jido.provider-qualification",
      "schema_version" => 1,
      "provider" => result.provider,
      "contract_version" => result.contract_version,
      "credentials" => result.credentials,
      "models" => result.models
    }
  end

  @doc "Returns true when every model in the report may stay in the supported tier."
  @spec supported?(report()) :: boolean()
  def supported?(%{models: models}) do
    models != [] and Enum.all?(models, &(&1["tier"] == "supported"))
  end

  defp provider_entries(provider, opts) do
    with {:ok, entries} <- Models.list(opts) do
      case Enum.filter(entries, &(&1.provider == provider)) do
        [] -> {:error, {:unknown_provider, provider}}
        matches -> {:ok, matches}
      end
    end
  end

  defp qualify_models(entries, opts) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case qualify_model(entry, opts) do
        {:ok, model} -> {:cont, {:ok, acc ++ [model]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp qualify_model(entry, opts) do
    with {:ok, harness} <- Harness.run(Keyword.put(opts, :entry, entry)) do
      eligible? = eligible?(entry, harness)
      published = if entry.tier == :supported and eligible?, do: "supported", else: "available"

      {:ok,
       %{
         "identity" => entry.identity,
         "model" => entry.model,
         "published_tier" => Atom.to_string(entry.tier),
         "tier" => published,
         "eligible" => eligible?,
         "limits" => stringify_map(entry.limits),
         "cost" => stringify_map(entry.cost),
         "known_gaps" => entry.known_gaps,
         "capabilities" => capability_matrix(entry, harness),
         "extra" => extra_results(entry, harness),
         "offline" => decision_map(offline_result(entry)),
         "preflight" => decision_map(preflight_result(entry)),
         "fallback" => decision_map(fallback_result(entry))
       }}
    end
  end

  defp eligible?(entry, harness) do
    Catalog.claimed_features(entry) != [] and
      Enum.all?(harness, &result_matches_entry?(&1, entry)) and
      Enum.all?(entry.capabilities, fn {dimension, feature} ->
        result = Enum.find(harness, &(&1.dimension == dimension))
        claim_matches_result?(feature, result)
      end)
  end

  defp capability_matrix(entry, harness) do
    entry.capabilities
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {dimension, feature} ->
      result = Enum.find(harness, &(&1.dimension == dimension))

      result_row(result)
      |> Map.merge(%{
        "dimension" => Atom.to_string(dimension),
        "claim" => Atom.to_string(feature.state),
        "claim_evidence_id" => feature.evidence,
        "claim_matches" => claim_matches_result?(feature, result)
      })
    end)
  end

  defp extra_results(entry, harness) do
    Enum.map(@extra_dimensions, fn dimension ->
      result = Enum.find(harness, &(&1.dimension == dimension))

      result_row(result)
      |> Map.merge(%{
        "dimension" => Atom.to_string(dimension),
        "claim_evidence_id" => entry.evidence_id,
        "claim_matches" => result_matches_entry?(result, entry)
      })
    end)
  end

  defp result_row(nil) do
    %{
      "contract_version" => nil,
      "evidence_id" => nil,
      "reason" => "no harness result",
      "status" => "missing",
      "test_id" => nil
    }
  end

  defp result_row(result) do
    %{
      "contract_version" => result.contract_version,
      "evidence_id" => result.evidence_id,
      "reason" => result.reason,
      "status" => Atom.to_string(result.status),
      "test_id" => result.test_id
    }
  end

  defp result_matches_entry?(nil, _entry), do: false

  defp result_matches_entry?(result, entry) do
    result.status == :pass and result.evidence_id == entry.evidence_id
  end

  defp claim_matches_result?(_feature, nil), do: false

  defp claim_matches_result?(feature, result) do
    result.status == claim_status(feature.state) and result.evidence_id == feature.evidence
  end

  defp claim_status(:supported), do: :pass
  defp claim_status(:unsupported), do: :fail
  defp claim_status(:unknown), do: :blocked
  defp claim_status(:not_applicable), do: :not_applicable

  defp offline_result(entry) do
    Preflight.check(
      provider: entry.provider,
      model: entry.model,
      entry: entry,
      offline: true,
      network: fn -> raise "offline qualification must not call the network" end,
      credentials: fn -> raise "offline qualification must not resolve credentials" end
    )
  end

  defp preflight_result(entry) do
    required = entry |> Catalog.claimed_features() |> Enum.map(&elem(&1, 0))

    Preflight.check(provider: entry.provider, model: entry.model, entry: entry, required_features: required)
  end

  defp fallback_result(entry) do
    Preflight.check(
      provider: entry.provider,
      model: entry.model,
      entry: entry,
      current: %{provider: entry.provider, cost_class: :standard},
      fallback: %{provider: "other", model: "other", cost_class: :higher}
    )
  end

  defp decision_map({:ok, decision}), do: decision_map(decision)
  defp decision_map({:error, decision}), do: decision_map(decision)

  defp decision_map(decision) do
    %{"outcome" => Atom.to_string(decision.outcome), "reason" => Redaction.redact(decision.reason)}
  end

  defp credential_record(provider, opts) do
    with {:ok, rows} <- Auth.status(Keyword.put(opts, :provider, provider)) do
      row = hd(rows)

      {:ok,
       %{
         "state" => Atom.to_string(row.state),
         "source" => Atom.to_string(row.source),
         "variable" => row.variable,
         "reason" => row.reason
       }}
    end
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), if(is_atom(value), do: Atom.to_string(value), else: value)}
    end)
  end
end
