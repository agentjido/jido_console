defmodule Jido.Console.Models.Catalog do
  @moduledoc """
  Versioned model catalog schema, validation, and v0.1 support policy.

  An entry is rejected when the support tier is unknown, the identity is
  duplicated, required capability fields are missing, or a supported claim has
  no contract evidence. LLMDB owns model metadata. Console configuration owns
  the smaller allowlist, support tiers, contract evidence, and known gaps.
  """

  @revision "jido.models.v0.1"
  @schema_version 1
  @tiers [:supported, :beta, :available, :unsupported]
  @selectable_tiers [:supported, :beta]
  @capability_keys [
    :streaming,
    :tools,
    :multi_turn_tools,
    :structured_results,
    :cancellation,
    :timeout,
    :prompt_cache
  ]
  @feature_states [:supported, :unsupported, :unknown, :not_applicable]
  @legacy_feature_fields [:cancellation, :prompt_cache, :contract_note, :prompt_cache_note]

  @type feature :: %{
          required(:state) => atom(),
          required(:evidence) => String.t() | nil,
          required(:note) => String.t()
        }
  @type entry :: %{
          required(:provider) => String.t(),
          required(:model) => String.t(),
          required(:identity) => String.t(),
          required(:tier) => atom(),
          required(:capabilities) => %{atom() => feature()},
          required(:limits) => map(),
          required(:cost) => map(),
          required(:known_gaps) => [String.t()],
          required(:evidence_id) => String.t(),
          required(:metadata) => map()
        }
  @type t :: %{revision: String.t(), schema_version: pos_integer(), entries: [entry()]}

  @doc "Returns the catalog revision identifier."
  @spec revision() :: String.t()
  def revision, do: @revision

  @doc "Returns the supported catalog tiers."
  @spec tiers() :: [atom()]
  def tiers, do: @tiers

  @doc "Returns model tiers that can be bound to an interactive session."
  @spec selectable_tiers() :: [atom()]
  def selectable_tiers, do: @selectable_tiers

  @doc "Loads the configured v0.1 policy or a caller-supplied entry list."
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts \\ []) do
    case Keyword.fetch(opts, :entries) do
      {:ok, entries} -> validate(entries)
      :error -> load_policy(opts)
    end
  end

  defp load_policy(opts) do
    policies = Keyword.get(opts, :model_policy, Application.get_env(:jido_console, :model_policy, []))
    resolver = Keyword.get(opts, :model_resolver, &LLMDB.model/1)

    with {:ok, entries} <- resolve_policies(policies, resolver) do
      validate(entries)
    end
  end

  defp resolve_policies([], resolver) when is_function(resolver, 1), do: {:error, :empty_model_policy}

  defp resolve_policies(policies, resolver) when is_list(policies) and is_function(resolver, 1) do
    policies
    |> Enum.reduce_while([], fn policy, entries ->
      case resolve_policy(policy, resolver) do
        {:ok, entry} -> {:cont, [entry | entries]}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      entries -> {:ok, Enum.reverse(entries)}
    end
  end

  defp resolve_policies(_policies, _resolver), do: {:error, :invalid_model_policy}

  defp resolve_policy(policy, resolver) when is_map(policy) do
    with {:ok, identity} <- policy_string(policy, :identity),
         {:ok, provider, model} <- parse_identity(identity),
         {:ok, tier} <- policy_tier(policy, identity),
         {:ok, evidence_id} <- policy_string(policy, :evidence_id),
         :ok <- reject_legacy_feature_fields(policy),
         {:ok, capabilities} <- policy_capabilities(policy),
         {:ok, known_gaps} <- policy_string_list(policy, :known_gaps),
         {:ok, llm_model} <- resolve_model(resolver, identity),
         :ok <- match_model_identity(llm_model, provider, model, identity),
         :ok <- supported_model_executable(tier, llm_model, identity) do
      {:ok,
       policy_entry(
         provider,
         model,
         tier,
         evidence_id,
         capabilities,
         known_gaps,
         llm_model
       )}
    end
  end

  defp resolve_policy(_policy, _resolver), do: {:error, :invalid_model_policy_entry}

  defp resolve_model(resolver, identity) do
    case resolver.(identity) do
      {:ok, %LLMDB.Model{} = model} -> {:ok, model}
      {:error, reason} -> {:error, {:model_metadata_unavailable, identity, reason}}
      other -> {:error, {:invalid_model_metadata_result, identity, other}}
    end
  rescue
    exception -> {:error, {:model_metadata_unavailable, identity, exception.__struct__}}
  end

  defp match_model_identity(%LLMDB.Model{} = llm_model, provider, model, identity) do
    resolved_provider = Atom.to_string(llm_model.provider)
    resolved_model = llm_model.provider_model_id || llm_model.model || llm_model.id

    if {resolved_provider, resolved_model} == {provider, model},
      do: :ok,
      else: {:error, {:model_identity_mismatch, identity, resolved_provider <> ":" <> resolved_model}}
  end

  defp supported_model_executable(:supported, %LLMDB.Model{} = model, identity) do
    cond do
      model.retired ->
        {:error, {:supported_model_retired, identity}}

      model.catalog_only ->
        {:error, {:supported_model_catalog_only, identity}}

      get_in(model.execution || %{}, [:text, :supported]) != true ->
        {:error, {:supported_model_not_executable, identity}}

      true ->
        :ok
    end
  end

  defp supported_model_executable(_tier, _model, _identity), do: :ok

  @doc "Validates catalog entries and returns a revisioned catalog."
  @spec validate([map()]) :: {:ok, t()} | {:error, term()}
  def validate(entries) when is_list(entries) do
    with :ok <- reject_unknown_tiers(entries),
         :ok <- reject_duplicate_identities(entries),
         {:ok, normalized} <- normalize_entries(entries),
         :ok <- reject_supported_without_evidence(normalized) do
      {:ok, %{revision: @revision, schema_version: @schema_version, entries: normalized}}
    end
  end

  def validate(_entries), do: {:error, :invalid_catalog}

  @doc "Fetches one entry by exact provider and model identity."
  @spec fetch(t(), String.t(), String.t()) :: {:ok, entry()} | {:error, term()}
  def fetch(%{entries: entries}, provider, model) do
    identity = identity(provider, model)

    case Enum.find(entries, &(&1.identity == identity)) do
      nil -> {:error, {:unknown_model, identity}}
      entry -> {:ok, entry}
    end
  end

  @doc "Fetches and validates one selectable complete model identity."
  @spec select(t(), String.t()) :: {:ok, entry()} | {:error, term()}
  def select(%{entries: _entries} = catalog, identity) when is_binary(identity) do
    with {:ok, provider, model} <- parse_identity(identity),
         {:ok, entry} <- fetch(catalog, provider, model),
         true <- entry.tier in @selectable_tiers do
      {:ok, entry}
    else
      false -> {:error, {:unsupported_model, identity}}
      {:error, {:unknown_model, ^identity}} -> {:error, {:unsupported_model, identity}}
      {:error, _reason} = error -> error
    end
  end

  def select(_catalog, identity), do: {:error, {:invalid_model_identity, identity}}

  @doc "Returns supported capabilities."
  @spec claimed_features(entry()) :: [{atom(), feature()}]
  def claimed_features(entry) do
    entry.capabilities
    |> Enum.filter(fn {_key, feature} -> feature.state == :supported end)
  end

  defp reject_unknown_tiers(entries) do
    case Enum.find(entries, fn entry -> is_map(entry) and entry_tier(entry) not in @tiers end) do
      nil -> :ok
      entry -> {:error, {:unknown_tier, entry_tier(entry), identity_of(entry)}}
    end
  end

  defp reject_duplicate_identities(entries) do
    identities = entries |> Enum.filter(&is_map/1) |> Enum.map(&identity_of/1)

    case identities -- Enum.uniq(identities) do
      [] -> :ok
      [identity | _rest] -> {:error, {:duplicate_identity, identity}}
    end
  end

  defp reject_supported_without_evidence(entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      cond do
        entry.tier == :supported and not evidence?(entry.evidence_id) ->
          {:halt, {:error, {:supported_without_evidence, entry.identity}}}

        unsupported_presented_as_supported?(entry) ->
          {:halt, {:error, {:unsupported_feature_claimed, entry.identity}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp unsupported_presented_as_supported?(entry) do
    Enum.any?(entry.capabilities, fn {_key, feature} ->
      feature.state == :supported and not evidence?(feature.evidence)
    end)
  end

  defp normalize_entries(entries) do
    entries
    |> Enum.reduce_while([], fn entry, acc ->
      case normalize_entry(entry) do
        {:ok, normalized} -> {:cont, [normalized | acc]}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      normalized -> {:ok, Enum.reverse(normalized)}
    end
  end

  defp normalize_entry(entry) when is_map(entry) do
    with {:ok, provider} <- required_string(entry, :provider),
         {:ok, model} <- required_string(entry, :model),
         {:ok, tier} <- required_atom(entry, :tier),
         {:ok, evidence_id} <- required_string(entry, :evidence_id),
         :ok <- reject_legacy_feature_fields(entry),
         {:ok, capabilities} <- normalize_capabilities(entry),
         {:ok, limits} <- required_map(entry, :limits),
         {:ok, cost} <- required_map(entry, :cost),
         {:ok, known_gaps} <- required_string_list(entry, :known_gaps),
         {:ok, metadata} <- optional_metadata(entry) do
      {:ok,
       %{
         provider: provider,
         model: model,
         identity: identity(provider, model),
         tier: tier,
         capabilities: capabilities,
         limits: limits,
         cost: cost,
         known_gaps: known_gaps,
         evidence_id: evidence_id,
         metadata: metadata
       }}
    end
  end

  defp normalize_entry(_entry), do: {:error, :invalid_catalog_entry}

  defp normalize_capabilities(entry) do
    case field(entry, :capabilities) do
      capabilities when is_map(capabilities) ->
        normalize_capability_map(capabilities, identity_of(entry))

      _other ->
        {:error, {:missing_field, :capabilities, identity_of(entry)}}
    end
  end

  defp normalize_capability_map(capabilities, identity) do
    with {:ok, canonical} <- canonical_capability_map(capabilities, identity) do
      @capability_keys
      |> Enum.reduce_while(%{}, fn key, acc ->
        case feature(canonical, key) do
          {:ok, value} -> {:cont, Map.put(acc, key, value)}
          {:error, :missing_feature} -> {:halt, {:error, {:missing_field, {:capabilities, key}, identity}}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:error, _reason} = error -> error
        normalized -> {:ok, normalized}
      end
    end
  end

  defp canonical_capability_map(capabilities, identity) do
    Enum.reduce_while(capabilities, {:ok, %{}}, fn {source_key, value}, {:ok, acc} ->
      case normalize_capability_key(source_key) do
        {:ok, key} when is_map_key(acc, key) ->
          {:halt, {:error, {:duplicate_capability, key, identity}}}

        {:ok, key} ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        :error ->
          {:halt, {:error, {:unknown_capability, source_key, identity}}}
      end
    end)
  end

  defp normalize_capability_key(key) when key in @capability_keys, do: {:ok, key}

  defp normalize_capability_key(key) when is_binary(key) do
    case Enum.find(@capability_keys, &(Atom.to_string(&1) == key)) do
      nil -> :error
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_capability_key(_key), do: :error

  defp reject_legacy_feature_fields(entry) do
    case Enum.find(@legacy_feature_fields, &has_field?(entry, &1)) do
      nil -> :ok
      key -> {:error, {:feature_outside_capabilities, key, identity_of(entry)}}
    end
  end

  defp feature(container, key) do
    case field(container, key) do
      nil ->
        {:error, :missing_feature}

      value when is_map(value) ->
        state = field(value, :state)
        evidence = field(value, :evidence)
        note = field(value, :note)

        cond do
          state not in @feature_states -> {:error, {:invalid_feature_state, key, state}}
          not is_binary(note) -> {:error, {:missing_field, {key, :note}, nil}}
          true -> {:ok, %{state: state, evidence: evidence, note: note}}
        end

      _other ->
        {:error, {:invalid_feature, key}}
    end
  end

  defp required_string(entry, key) do
    case field(entry, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_field, key, identity_of(entry)}}
    end
  end

  defp required_atom(entry, key) do
    case field(entry, key) do
      value when is_atom(value) -> {:ok, value}
      value when is_binary(value) -> {:ok, String.to_existing_atom(value)}
      _other -> {:error, {:missing_field, key, identity_of(entry)}}
    end
  rescue
    ArgumentError -> {:error, {:unknown_tier, field(entry, key), identity_of(entry)}}
  end

  defp required_map(entry, key) do
    case field(entry, key) do
      value when is_map(value) and map_size(value) > 0 -> {:ok, value}
      _other -> {:error, {:missing_field, key, identity_of(entry)}}
    end
  end

  defp required_string_list(entry, key) do
    case field(entry, key) do
      value when is_list(value) ->
        if Enum.all?(value, &(is_binary(&1) and &1 != "")),
          do: {:ok, value},
          else: {:error, {:missing_field, key, identity_of(entry)}}

      _other ->
        {:error, {:missing_field, key, identity_of(entry)}}
    end
  end

  defp optional_metadata(entry) do
    case field(entry, :metadata) do
      nil -> {:ok, %{source: :declared}}
      value when is_map(value) -> {:ok, value}
      _other -> {:error, {:invalid_field, :metadata, identity_of(entry)}}
    end
  end

  defp identity(provider, model), do: provider <> ":" <> model

  defp identity_of(entry) do
    case {field(entry, :provider), field(entry, :model)} do
      {provider, model} when is_binary(provider) and is_binary(model) -> identity(provider, model)
      _other -> field(entry, :identity) || "unknown"
    end
  end

  defp entry_tier(entry) do
    case field(entry, :tier) do
      value when is_atom(value) -> value
      value when is_binary(value) -> String.to_existing_atom(value)
      _other -> :invalid
    end
  rescue
    ArgumentError -> :invalid
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp has_field?(map, key) when is_map(map),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp evidence?(value) when is_binary(value), do: String.starts_with?(value, ["contract:", "harness:"])
  defp evidence?(_value), do: false

  defp parse_identity(identity) do
    case String.split(identity, ":", parts: 2) do
      [provider, model] when provider != "" and model != "" -> {:ok, provider, model}
      _other -> {:error, {:invalid_model_identity, identity}}
    end
  end

  defp policy_string(policy, key) do
    case field(policy, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:invalid_model_policy_field, key}}
    end
  end

  defp policy_string_list(policy, key) do
    case field(policy, key) do
      values when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and &1 != "")),
          do: {:ok, values},
          else: {:error, {:invalid_model_policy_field, key}}

      _other ->
        {:error, {:invalid_model_policy_field, key}}
    end
  end

  defp policy_capabilities(policy) do
    case field(policy, :capabilities) do
      capabilities when is_map(capabilities) ->
        normalize_capability_map(capabilities, identity_of(policy))

      _other ->
        {:error, {:invalid_model_policy_field, :capabilities}}
    end
  end

  defp policy_tier(policy, identity) do
    case field(policy, :tier) do
      tier when tier in @tiers -> {:ok, tier}
      tier -> {:error, {:unknown_tier, tier, identity}}
    end
  end

  defp policy_entry(
         provider,
         model,
         tier,
         evidence_id,
         capabilities,
         known_gaps,
         llm_model
       ) do
    %{
      provider: provider,
      model: model,
      tier: tier,
      evidence_id: evidence_id,
      capabilities: capabilities,
      limits: model_limits(llm_model),
      cost: model_cost(llm_model, tier),
      known_gaps: known_gaps ++ lifecycle_gaps(llm_model),
      metadata: model_metadata(llm_model)
    }
  end

  defp model_limits(%LLMDB.Model{limits: limits}) when is_map(limits) do
    %{
      context_tokens: Map.get(limits, :context, :unknown),
      output_tokens: Map.get(limits, :output, :unknown)
    }
  end

  defp model_limits(_model), do: %{context_tokens: :unknown, output_tokens: :unknown}

  defp model_cost(%LLMDB.Model{} = model, tier) do
    currency = get_in(model.pricing || %{}, [:currency]) || "USD"
    cost_class = if tier == :supported, do: :standard, else: :unknown

    (model.cost || %{})
    |> Map.put(:class, cost_class)
    |> Map.put(:currency, currency)
  end

  defp model_metadata(%LLMDB.Model{} = model) do
    %{
      source: :llm_db,
      deprecated: model.deprecated,
      retired: model.retired,
      lifecycle: model.lifecycle,
      execution: model.execution
    }
  end

  defp lifecycle_gaps(%LLMDB.Model{lifecycle: lifecycle, deprecated: true}) do
    replacement = if is_map(lifecycle), do: Map.get(lifecycle, :replacement)
    retirement = if is_map(lifecycle), do: Map.get(lifecycle, :retires_at)

    [
      "LLMDB marks this model deprecated" <>
        optional_label("; replacement ", replacement) <>
        optional_label("; retirement ", retirement)
    ]
  end

  defp lifecycle_gaps(_model), do: []

  defp optional_label(_prefix, value) when value in [nil, ""], do: ""
  defp optional_label(prefix, value), do: prefix <> to_string(value)
end
