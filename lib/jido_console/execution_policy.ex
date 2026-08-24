defmodule Jido.Console.ExecutionPolicy.Consent do
  @moduledoc false

  @type direct_origin :: :cli | :api | :tui

  @opaque t :: %__MODULE__{
            execution_policy_id: String.t() | nil,
            origin: direct_origin() | :stored | atom() | nil,
            legacy?: boolean(),
            thread_id: String.t() | nil,
            evidence_digest: String.t() | nil,
            seal: term()
          }

  defstruct execution_policy_id: nil,
            origin: nil,
            legacy?: false,
            thread_id: nil,
            evidence_digest: nil,
            seal: nil
end

defmodule Jido.Console.ExecutionPolicy do
  @moduledoc """
  Host-owned execution-policy identity and consent boundary.

  An agent can supply only an inert policy request ID. A broader policy is
  selected only with a typed value minted at a direct CLI, API, or pre-turn
  TUI boundary.
  """

  alias __MODULE__.Consent
  alias __MODULE__.Selection
  alias Jidoka.ExecutionEnvironment.PolicyRequest

  @restricted_id "coding.restricted"
  @trusted_id "coding.trusted-workspace"
  @trusted_alias "coding.local"
  @environment_allowlist ~w(PATH LANG TERM TMPDIR HOME)
  @direct_origins [:cli, :api, :tui]
  @consent_seal {__MODULE__, :consent, 1}
  @legacy_warning "coding profile is deprecated; use execution policy"

  @doc "Returns the automatic restricted execution-policy ID."
  @spec restricted_id() :: String.t()
  def restricted_id, do: @restricted_id

  @doc "Returns the canonical trusted-workspace execution-policy ID."
  @spec trusted_id() :: String.t()
  def trusted_id, do: @trusted_id

  @doc "Returns the one-release compatibility alias for trusted workspace."
  @spec trusted_alias() :: String.t()
  def trusted_alias, do: @trusted_alias

  @doc "Returns the warning shown for the broader trusted-workspace policy."
  @spec trusted_warning() :: String.t()
  def trusted_warning, do: "Trusted-workspace mode is not a sandbox."

  @doc "Returns the deterministic compatibility warning text."
  @spec legacy_warning() :: String.t()
  def legacy_warning, do: @legacy_warning

  @doc "Returns the default restricted process environment allowlist."
  @spec environment_allowlist() :: [String.t()]
  def environment_allowlist, do: @environment_allowlist

  @doc "Normalizes a policy ID before lookup, consent, evidence, or display."
  @spec normalize_id(term()) :: term()
  def normalize_id(nil), do: nil

  def normalize_id(id) when is_binary(id) do
    case String.trim(id) do
      @trusted_alias -> @trusted_id
      normalized -> normalized
    end
  end

  def normalize_id(value), do: value

  @doc "Builds the only Jidoka value that untrusted agent policy data can supply."
  @spec policy_request(String.t()) :: {:ok, PolicyRequest.t()} | {:error, term()}
  def policy_request(id) when is_binary(id) do
    case normalize_id(id) do
      "" -> {:error, :invalid_agent_execution_policy_request}
      normalized -> PolicyRequest.new(profile_id: normalized)
    end
  end

  def policy_request(_value), do: {:error, :invalid_agent_execution_policy_request}

  @doc "Mints one typed direct choice after same-layer conflict checks."
  @spec direct_choice(String.t() | keyword(), atom()) :: {:ok, Consent.t() | nil} | {:error, term()}
  def direct_choice(layer, origin) when is_list(layer) do
    with :ok <- direct_origin(origin),
         {:ok, value, legacy?} <- one_layer_value(layer),
         {:ok, choice} <- mint_direct(value, origin, legacy?) do
      {:ok, choice}
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
       %Consent{
         execution_policy_id: selection.execution_policy_id,
         origin: :stored,
         thread_id: thread_id,
         evidence_digest: selection.evidence["evidence_digest"],
         seal: @consent_seal
       }}
    else
      _invalid -> {:error, :invalid_execution_policy_selection}
    end
  end

  def store_consent(_selection, _thread_id), do: {:error, :invalid_execution_policy_selection}

  @doc false
  @spec valid_direct_consent?(term()) :: boolean()
  def valid_direct_consent?(%Consent{
        execution_policy_id: id,
        origin: origin,
        thread_id: nil,
        evidence_digest: nil,
        seal: @consent_seal
      })
      when is_binary(id) and origin in @direct_origins,
      do: true

  def valid_direct_consent?(_value), do: false

  @doc false
  @spec valid_stored_consent?(term()) :: boolean()
  def valid_stored_consent?(%Consent{
        execution_policy_id: id,
        origin: :stored,
        thread_id: thread_id,
        evidence_digest: digest,
        seal: @consent_seal
      })
      when is_binary(id) and is_binary(thread_id) and is_binary(digest),
      do: true

  def valid_stored_consent?(_value), do: false

  @doc "Runs the pure execution-policy selector."
  @spec resolve(keyword()) :: {:ok, Selection.t()} | {:error, term()}
  def resolve(opts \\ []), do: Selection.resolve(opts)

  @doc "Reads a canonical or legacy application proposal without granting consent."
  @spec application_proposal() :: {:ok, String.t() | nil} | {:error, term()}
  def application_proposal do
    canonical = Application.fetch_env(:jido_console, :execution_policy)
    legacy = Application.fetch_env(:jido_console, :coding_profile)

    case {canonical, legacy} do
      {{:ok, _value}, {:ok, _legacy}} -> {:error, :conflicting_execution_policy_inputs}
      {{:ok, value}, :error} -> normalize_proposal(value)
      {:error, {:ok, value}} -> normalize_proposal(value)
      {:error, :error} -> {:ok, nil}
    end
  end

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
        {:ok,
         %Consent{
           execution_policy_id: normalized,
           origin: origin,
           legacy?: legacy?,
           seal: @consent_seal
         }}
    end
  end

  defp mint_direct(value, _origin, _legacy?), do: {:error, {:invalid_execution_policy_input, value}}

  defp normalize_proposal(value) when is_binary(value) do
    case normalize_id(value) do
      "" -> {:error, {:invalid_execution_policy_input, value}}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_proposal(nil), do: {:ok, nil}
  defp normalize_proposal(value), do: {:error, {:invalid_execution_policy_input, value}}
end
