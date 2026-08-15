defmodule Jido.Console.Policy.Preflight do
  @moduledoc """
  Blocks unsupported model work and offline network use before a turn starts.

  A fallback that changes provider, data boundary, cost class, or capability is
  classified as consent-required and is not applied here.
  """

  alias Jido.Console.Models
  alias Jidoka.Policy.Decision

  @type decision :: %{
          outcome: atom(),
          model: String.t() | nil,
          provider: String.t() | nil,
          profile: String.t() | nil,
          required_features: [atom()],
          reason: String.t(),
          rule_id: String.t()
        }

  @doc "PrefLights one turn against the catalog, offline mode, and fallback policy."
  @spec check(keyword()) :: {:ok, decision()} | {:error, decision()}
  def check(opts \\ []) do
    cond do
      Keyword.get(opts, :offline, false) ->
        deny_offline(opts)

      fallback = Keyword.get(opts, :fallback) ->
        classify_fallback(fallback, opts)

      true ->
        preflight_model(opts)
    end
  end

  @doc "Returns a Jidoka policy decision for a Console preflight result."
  @spec to_jidoka(decision()) :: Decision.t()
  def to_jidoka(decision) do
    Decision.new!(
      outcome: jidoka_outcome(decision.outcome),
      rule_id: decision.rule_id,
      reason: decision.reason,
      evidence: %{
        "model" => decision.model,
        "provider" => decision.provider,
        "profile" => decision.profile,
        "required_features" => Enum.map(decision.required_features, &Atom.to_string/1)
      }
    )
  end

  defp preflight_model(opts) do
    provider = Keyword.fetch!(opts, :provider)
    model = Keyword.fetch!(opts, :model)
    required = List.wrap(Keyword.get(opts, :required_features, []))
    network = Keyword.get(opts, :network, fn -> :not_called end)
    credentials = Keyword.get(opts, :credentials, fn -> :not_called end)

    case load_entry(provider, model, opts) do
      {:error, {:unknown_model, identity}} ->
        {:error,
         decision(:deny, provider, model, required, opts, "unknown model #{identity}", "jido.policy.unknown_model")}

      {:ok, entry} ->
        case missing_feature(entry, required) do
          nil ->
            _ = network.()
            _ = credentials.()

            {:ok,
             decision(:allow, provider, model, required, opts, "required features are present", "jido.policy.allow")}

          {feature, reason} ->
            {:error,
             decision(
               :deny,
               provider,
               model,
               required,
               opts,
               "#{entry.identity} cannot provide #{feature}: #{reason}",
               "jido.policy.capability_denied"
             )}
        end
    end
  end

  defp load_entry(_provider, _model, opts) do
    case Keyword.get(opts, :entry) do
      %{} = entry -> {:ok, entry}
      nil -> Models.show(Keyword.fetch!(opts, :provider), Keyword.fetch!(opts, :model), opts)
    end
  end

  defp deny_offline(opts) do
    _network = Keyword.get(opts, :network, fn -> :not_called end)
    _credentials = Keyword.get(opts, :credentials, fn -> :not_called end)
    provider = Keyword.get(opts, :provider)
    model = Keyword.get(opts, :model)

    {:error,
     decision(
       :deny,
       provider,
       model,
       List.wrap(Keyword.get(opts, :required_features, [])),
       opts,
       "offline mode denies model network calls and credential resolution",
       "jido.policy.offline"
     )}
  end

  defp classify_fallback(fallback, opts) when is_map(fallback) do
    current = Keyword.get(opts, :current, %{})
    changes = fallback_changes(current, fallback)

    if changes == [] do
      preflight_model(Keyword.merge(opts, provider: fallback.provider, model: fallback.model))
    else
      {:error,
       decision(
         :consent_required,
         Map.get(fallback, :provider),
         Map.get(fallback, :model),
         List.wrap(Keyword.get(opts, :required_features, [])),
         opts,
         "fallback changes #{Enum.join(changes, ", ")} and requires consent",
         "jido.policy.fallback_consent"
       )}
    end
  end

  defp fallback_changes(current, fallback) do
    [
      {:provider, "provider"},
      {:data_boundary, "data boundary"},
      {:cost_class, "cost class"},
      {:capability, "capability"}
    ]
    |> Enum.flat_map(fn {key, label} ->
      if Map.get(current, key) not in [nil, Map.get(fallback, key)] and
           Map.has_key?(fallback, key),
         do: [label],
         else: []
    end)
  end

  defp missing_feature(entry, required) do
    Enum.find_value(required, fn feature ->
      case feature_state(entry, feature) do
        {:ok, %{state: :supported}} -> nil
        {:ok, %{state: state, note: note}} -> {feature, "#{state}: #{note}"}
        :error -> {feature, "missing from catalog"}
      end
    end)
  end

  defp feature_state(entry, :cancellation), do: {:ok, entry.cancellation}
  defp feature_state(entry, :prompt_cache), do: {:ok, entry.prompt_cache}

  defp feature_state(entry, feature) do
    case Map.fetch(entry.capabilities, feature) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp decision(outcome, provider, model, required, opts, reason, rule_id) do
    %{
      outcome: outcome,
      provider: provider,
      model: model,
      profile: Keyword.get(opts, :profile),
      required_features: required,
      reason: reason,
      rule_id: rule_id
    }
  end

  defp jidoka_outcome(:allow), do: :allow
  defp jidoka_outcome(:consent_required), do: :consent_required
  defp jidoka_outcome(:deny), do: :deny
end
