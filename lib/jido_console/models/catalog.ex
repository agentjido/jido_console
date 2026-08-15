defmodule Jido.Console.Models.Catalog do
  @moduledoc """
  Versioned model catalog schema, validation, and v0.1 entries.

  An entry is rejected when the support tier is unknown, the identity is
  duplicated, required capability fields are missing, or a supported claim has
  no contract evidence. Ollama stays in the beta tier until its beta contract
  passes.
  """

  @revision "jido.models.v0.1"
  @schema_version 1
  @tiers [:supported, :beta, :available, :unsupported]
  @capability_keys [
    :streaming,
    :tools,
    :multi_turn_tools,
    :structured_results,
    :cancellation,
    :timeout
  ]
  @feature_states [:supported, :unsupported, :unknown, :not_applicable]

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
          required(:cancellation) => feature(),
          required(:prompt_cache) => feature(),
          required(:known_gaps) => [String.t()],
          required(:evidence_id) => String.t()
        }
  @type t :: %{revision: String.t(), schema_version: pos_integer(), entries: [entry()]}

  @doc "Returns the catalog revision identifier."
  @spec revision() :: String.t()
  def revision, do: @revision

  @doc "Returns the supported catalog tiers."
  @spec tiers() :: [atom()]
  def tiers, do: @tiers

  @doc "Loads the built-in v0.1 catalog or a caller-supplied entry list."
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts \\ []) do
    entries = Keyword.get_lazy(opts, :entries, &builtin_entries/0)
    validate(entries)
  end

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

  defp reject_unknown_tiers(entries) do
    case Enum.find(entries, fn entry -> entry_tier(entry) not in @tiers end) do
      nil -> :ok
      entry -> {:error, {:unknown_tier, entry_tier(entry), identity_of(entry)}}
    end
  end

  defp reject_duplicate_identities(entries) do
    identities = Enum.map(entries, &identity_of/1)

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
    features = [entry.cancellation, entry.prompt_cache | Map.values(entry.capabilities)]

    Enum.any?(features, fn feature ->
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
         {:ok, capabilities} <- normalize_capabilities(entry),
         {:ok, limits} <- required_map(entry, :limits),
         {:ok, cost} <- required_map(entry, :cost),
         {:ok, cancellation} <- required_feature(entry, :cancellation),
         {:ok, prompt_cache} <- required_feature(entry, :prompt_cache),
         {:ok, known_gaps} <- required_string_list(entry, :known_gaps) do
      {:ok,
       %{
         provider: provider,
         model: model,
         identity: identity(provider, model),
         tier: tier,
         capabilities: capabilities,
         limits: limits,
         cost: cost,
         cancellation: cancellation,
         prompt_cache: prompt_cache,
         known_gaps: known_gaps,
         evidence_id: evidence_id
       }}
    end
  end

  defp normalize_entry(_entry), do: {:error, :invalid_catalog_entry}

  defp normalize_capabilities(entry) do
    capabilities = field(entry, :capabilities)

    if is_map(capabilities) do
      @capability_keys
      |> Enum.reduce_while(%{}, fn key, acc ->
        case feature(capabilities, key) do
          {:ok, value} -> {:cont, Map.put(acc, key, value)}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:error, _reason} = error -> error
        normalized -> {:ok, normalized}
      end
    else
      {:error, {:missing_field, :capabilities, identity_of(entry)}}
    end
  end

  defp required_feature(entry, key) do
    case feature(entry, key) do
      {:ok, value} -> {:ok, value}
      {:error, :missing_feature} -> {:error, {:missing_field, key, identity_of(entry)}}
      {:error, _reason} = error -> error
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

  defp identity(provider, model), do: provider <> ":" <> model

  defp identity_of(entry) do
    case {field(entry, :provider), field(entry, :model)} do
      {provider, model} when is_binary(provider) and is_binary(model) -> identity(provider, model)
      _other -> "unknown"
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

  defp evidence?(value) when is_binary(value), do: String.starts_with?(value, ["contract:", "harness:"])
  defp evidence?(_value), do: false

  defp builtin_entries do
    pending = fn note -> %{state: :unknown, evidence: nil, note: note} end

    [
      openai_gpt_4_1_mini(),
      builtin(
        "anthropic",
        "claude-sonnet-4-20250514",
        :available,
        "pending:m1e11",
        pending.("Awaiting Anthropic qualification"),
        ["No v0.1 support claim until M1-E11 contract evidence passes"]
      ),
      builtin(
        "google",
        "gemini-2.5-flash",
        :available,
        "pending:m1e12",
        pending.("Awaiting Google Gemini qualification"),
        ["No v0.1 support claim until M1-E12 contract evidence passes"]
      ),
      builtin(
        "ollama",
        "llama3.2",
        :beta,
        "pending:ollama-beta",
        pending.("Ollama remains beta until its beta contract passes"),
        ["Local-only beta. Not a v0.1 supported-tier claim."]
      )
    ]
  end

  defp openai_gpt_4_1_mini do
    evidence = "harness:openai:gpt-4.1-mini"
    supported = %{state: :supported, evidence: evidence, note: "Recorded OpenAI v0.1 contract"}

    %{
      provider: "openai",
      model: "gpt-4.1-mini",
      tier: :supported,
      evidence_id: evidence,
      capabilities: Map.new(@capability_keys, &{&1, supported}),
      limits: %{context_tokens: 1_047_576, output_tokens: 32_768},
      cost: %{class: :standard, currency: "USD"},
      cancellation: supported,
      prompt_cache: %{
        state: :supported,
        evidence: evidence,
        note: "Automatic prompt cache; no explicit cache-control API"
      },
      known_gaps: [
        "Recorded qualification does not call a live OpenAI endpoint",
        "Prompt cache is automatic and not separately configurable",
        "Cost class is catalog metadata, not a live invoice"
      ]
    }
  end

  defp builtin(provider, model, tier, evidence_id, feature, known_gaps) do
    %{
      provider: provider,
      model: model,
      tier: tier,
      evidence_id: evidence_id,
      capabilities: Map.new(@capability_keys, &{&1, feature}),
      limits: %{context_tokens: :unknown, output_tokens: :unknown},
      cost: %{class: :unknown, currency: "USD"},
      cancellation: feature,
      prompt_cache: feature,
      known_gaps: known_gaps
    }
  end
end
