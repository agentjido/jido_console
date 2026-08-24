defmodule Jido.Console.ExecutionPolicy do
  @moduledoc """
  Host-owned execution-policy identity and consent boundary.

  An agent can supply only an inert policy request ID. A broader policy is
  selected only with a typed value minted at a direct CLI, API, or pre-turn
  TUI boundary.
  """

  alias __MODULE__.Consent
  alias __MODULE__.Configuration
  alias __MODULE__.Definition
  alias __MODULE__.Selection

  @direct_origins [:cli, :api, :tui]

  @doc "Returns the automatic restricted execution-policy ID."
  @spec restricted_id() :: String.t()
  defdelegate restricted_id, to: Definition

  @doc "Returns the canonical trusted-workspace execution-policy ID."
  @spec trusted_id() :: String.t()
  defdelegate trusted_id, to: Definition

  @doc "Returns the one-release compatibility alias for trusted workspace."
  @spec trusted_alias() :: String.t()
  defdelegate trusted_alias, to: Definition

  @doc "Returns the warning shown for the broader trusted-workspace policy."
  @spec trusted_warning() :: String.t()
  defdelegate trusted_warning, to: Definition

  @doc "Returns the deterministic compatibility warning text."
  @spec legacy_warning() :: String.t()
  defdelegate legacy_warning, to: Definition

  @doc false
  @spec warn_legacy() :: :ok
  defdelegate warn_legacy, to: Configuration

  @doc "Returns the default restricted process environment allowlist."
  @spec environment_allowlist() :: [String.t()]
  defdelegate environment_allowlist, to: Definition

  @doc "Normalizes a policy ID before lookup, consent, evidence, or display."
  @spec normalize_id(term()) :: term()
  defdelegate normalize_id(value), to: Definition

  @doc "Builds the only Jidoka value that untrusted agent policy data can supply."
  @spec policy_request(String.t()) ::
          {:ok, Jidoka.ExecutionEnvironment.PolicyRequest.t()} | {:error, term()}
  defdelegate policy_request(id), to: Definition

  @doc "Mints one typed direct choice after same-layer conflict checks."
  @spec direct_choice(String.t() | keyword(), atom()) :: {:ok, Consent.t() | nil} | {:error, term()}
  def direct_choice(layer, origin) when is_list(layer) do
    with :ok <- direct_origin(origin),
         {:ok, value, legacy?} <- one_layer_value(layer) do
      mint_direct(value, origin, legacy?)
    end
  end

  def direct_choice(id, origin) when is_binary(id) do
    with :ok <- direct_origin(origin), do: mint_direct(id, origin, false)
  end

  def direct_choice(_id, origin) when origin not in @direct_origins,
    do: {:error, {:invalid_execution_policy_consent_origin, origin}}

  def direct_choice(value, _origin), do: {:error, {:invalid_execution_policy_input, value}}

  @doc "Stores direct consent as exact thread and policy-evidence data."
  @spec store_consent(Selection.t(), String.t()) :: {:ok, Consent.t()} | {:error, term()}
  def store_consent(selection, thread_id) when is_binary(thread_id) and thread_id != "" do
    with true <- is_struct(selection, Selection),
         {:ok, selection} <- Selection.validate_for_storage(selection) do
      {:ok,
       Consent.stored(
         selection.execution_policy_id,
         thread_id,
         selection.evidence["evidence_digest"]
       )}
    else
      _invalid -> {:error, :invalid_execution_policy_selection}
    end
  end

  def store_consent(_selection, _thread_id), do: {:error, :invalid_execution_policy_selection}

  @doc false
  @spec valid_direct_consent?(term()) :: boolean()
  defdelegate valid_direct_consent?(value), to: Consent, as: :valid_direct?

  @doc false
  @spec valid_stored_consent?(term()) :: boolean()
  defdelegate valid_stored_consent?(value), to: Consent, as: :valid_stored?

  @doc "Runs the pure execution-policy selector."
  @spec resolve(keyword()) :: {:ok, Selection.t()} | {:error, term()}
  def resolve(opts \\ []), do: Selection.resolve(opts)

  @doc "Reads a canonical or legacy application proposal without granting consent."
  @spec application_proposal() :: {:ok, String.t() | nil} | {:error, term()}
  defdelegate application_proposal, to: Configuration

  @doc "Checks canonical and legacy resolver keys before a layer is merged."
  @spec resolver_from_layer(keyword()) :: {:ok, term()} | {:error, term()}
  def resolver_from_layer(layer) when is_list(layer) do
    canonical = Keyword.get_values(layer, :execution_policy_resolver)
    legacy = Keyword.get_values(layer, :coding_profile_resolver)

    cond do
      canonical != [] and legacy != [] -> {:error, :conflicting_execution_policy_inputs}
      length(canonical) > 1 or length(legacy) > 1 -> {:error, :repeated_execution_policy_resolver_input}
      canonical != [] -> {:ok, hd(canonical)}
      legacy != [] -> {:ok, hd(legacy)}
      true -> {:ok, nil}
    end
  end

  def resolver_from_layer(_layer), do: {:error, :invalid_execution_policy_input_layer}

  defp direct_origin(origin) when origin in @direct_origins, do: :ok
  defp direct_origin(origin), do: {:error, {:invalid_execution_policy_consent_origin, origin}}

  defp one_layer_value(layer) do
    if Keyword.keyword?(layer) do
      canonical = Keyword.get_values(layer, :execution_policy)
      legacy = Keyword.get_values(layer, :coding_profile)

      cond do
        canonical != [] and legacy != [] -> {:error, :conflicting_execution_policy_inputs}
        length(canonical) > 1 or length(legacy) > 1 -> {:error, :repeated_execution_policy_input}
        canonical != [] -> {:ok, hd(canonical), false}
        legacy != [] -> {:ok, hd(legacy), true}
        true -> {:ok, nil, false}
      end
    else
      {:error, :invalid_execution_policy_input_layer}
    end
  end

  defp mint_direct(nil, _origin, _legacy?), do: {:ok, nil}

  defp mint_direct(id, origin, legacy?) when is_binary(id) do
    case normalize_id(id) do
      "" ->
        {:error, {:invalid_execution_policy_input, id}}

      normalized ->
        {:ok, Consent.direct(normalized, origin, legacy?)}
    end
  end

  defp mint_direct(value, _origin, _legacy?), do: {:error, {:invalid_execution_policy_input, value}}
end
