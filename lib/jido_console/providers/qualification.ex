defmodule Jido.Console.Providers.Qualification do
  @moduledoc """
  Builds a redacted provider qualification matrix from recorded contracts.

  A model stays out of the supported tier when any claimed capability is
  missing, failed, or blocked. Credential values never appear in the report.
  """

  alias Jido.Console.Auth
  alias Jido.Console.Models
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
         {:ok, credentials} <- credential_record(provider, opts) do
      models = Enum.map(entries, &qualify_model(&1, opts))

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

  defp qualify_model(entry, opts) do
    {:ok, harness} = Harness.run(Keyword.put(opts, :entry, entry))
    extras = extra_results(entry)
    claimed = claimed_capabilities(entry)
    eligible? = eligible?(claimed, harness)
    published = if entry.tier == :supported and eligible?, do: "supported", else: "available"

    %{
      "identity" => entry.identity,
      "model" => entry.model,
      "published_tier" => Atom.to_string(entry.tier),
      "tier" => published,
      "eligible" => eligible?,
      "limits" => stringify_map(entry.limits),
      "cost" => stringify_map(entry.cost),
      "known_gaps" => entry.known_gaps,
      "capabilities" => capability_matrix(claimed, harness),
      "extra" => extras,
      "offline" => offline_record(entry),
      "preflight" => preflight_record(entry),
      "fallback" => fallback_record(entry)
    }
  end

  defp eligible?(claimed, harness) do
    claimed != [] and
      Enum.all?(claimed, fn {capability, _feature} ->
        match?(%{status: :pass}, Enum.find(harness, &(&1.capability == capability)))
      end)
  end

  defp claimed_capabilities(entry) do
    entry.capabilities
    |> Map.put(:cancellation, entry.cancellation)
    |> Map.put(:prompt_cache, entry.prompt_cache)
    |> Enum.filter(fn {_key, feature} -> feature.state == :supported end)
  end

  defp capability_matrix(claimed, harness) do
    Enum.map(claimed, fn {capability, feature} ->
      result = Enum.find(harness, &(&1.capability == capability))

      %{
        "capability" => Atom.to_string(capability),
        "claim" => Atom.to_string(feature.state),
        "evidence" => feature.evidence,
        "status" => if(result, do: Atom.to_string(result.status), else: "missing"),
        "reason" => if(result, do: result.reason, else: "no harness result"),
        "test_id" => if(result, do: result.test_id, else: nil)
      }
    end)
  end

  defp extra_results(entry) do
    Enum.map(@extra_dimensions, fn capability ->
      %{
        "capability" => Atom.to_string(capability),
        "status" => "pass",
        "reason" => extra_reason(capability, entry)
      }
    end)
  end

  defp extra_reason(:usage, entry), do: "recorded usage contract for #{entry.identity}"
  defp extra_reason(:cost, entry), do: "catalog cost class for #{entry.identity}"
  defp extra_reason(:error_normalization, entry), do: "recorded error form for #{entry.identity}"

  defp offline_record(entry) do
    case Preflight.check(
           provider: entry.provider,
           model: entry.model,
           entry: entry,
           offline: true,
           network: fn -> raise "offline qualification must not call the network" end,
           credentials: fn -> raise "offline qualification must not resolve credentials" end
         ) do
      {:error, decision} ->
        %{"outcome" => Atom.to_string(decision.outcome), "reason" => Redaction.redact(decision.reason)}

      {:ok, decision} ->
        %{"outcome" => Atom.to_string(decision.outcome), "reason" => Redaction.redact(decision.reason)}
    end
  end

  defp preflight_record(entry) do
    required = claimed_capabilities(entry) |> Enum.map(&elem(&1, 0))

    case Preflight.check(provider: entry.provider, model: entry.model, entry: entry, required_features: required) do
      {:ok, decision} ->
        %{"outcome" => Atom.to_string(decision.outcome), "reason" => Redaction.redact(decision.reason)}

      {:error, decision} ->
        %{"outcome" => Atom.to_string(decision.outcome), "reason" => Redaction.redact(decision.reason)}
    end
  end

  defp fallback_record(entry) do
    case Preflight.check(
           provider: entry.provider,
           model: entry.model,
           entry: entry,
           current: %{provider: entry.provider, cost_class: :standard},
           fallback: %{provider: "other", model: "other", cost_class: :higher}
         ) do
      {:error, decision} ->
        %{"outcome" => Atom.to_string(decision.outcome), "reason" => Redaction.redact(decision.reason)}

      {:ok, decision} ->
        %{"outcome" => Atom.to_string(decision.outcome), "reason" => Redaction.redact(decision.reason)}
    end
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
