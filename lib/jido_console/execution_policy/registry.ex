defmodule Jido.Console.ExecutionPolicy.Registry do
  @moduledoc "Trusted host registry for Console execution policies."

  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.ExecutionPolicy.Record

  alias Jidoka.ExecutionEnvironment

  alias Jidoka.ExecutionEnvironment.{
    AdapterCapabilities,
    PolicyRequest,
    ProfileResolver,
    Registration,
    SecurityProfile
  }

  @adapter_id "jido_console.local_folder"
  @adapter_version "1"
  @maximum_limits %{"wall_time_ms" => 120_000, "output_bytes" => 262_144}
  @capability_ids ["shell.execute"]

  @enforce_keys [:records]
  defstruct [:records]

  @type t :: %__MODULE__{records: %{String.t() => Record.t()}}

  @doc "Builds the built-in trusted registry without opening runtime resources."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    with {:ok, restricted} <- build_record(ExecutionPolicy.restricted_id(), :restricted, false, nil, opts),
         {:ok, trusted} <-
           build_record(
             ExecutionPolicy.trusted_id(),
             :trusted_workspace,
             true,
             ExecutionPolicy.trusted_warning(),
             opts
           ) do
      {:ok,
       %__MODULE__{
         records: %{
           restricted.execution_policy_id => restricted,
           trusted.execution_policy_id => trusted
         }
       }}
    end
  rescue
    exception -> {:error, {:invalid_execution_policy_registry, exception}}
  end

  def new(_opts), do: {:error, :invalid_execution_policy_registry_options}

  @doc "Builds the registry and raises if trusted host configuration is invalid."
  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, registry} -> registry
      {:error, reason} -> raise ArgumentError, "invalid execution-policy registry: #{inspect(reason)}"
    end
  end

  @doc "Fetches one canonical record after alias normalization."
  @spec fetch(t(), String.t()) :: {:ok, Record.t()} | {:error, term()}
  def fetch(%__MODULE__{records: records}, id) when is_binary(id) do
    id = ExecutionPolicy.normalize_id(id)

    case Map.fetch(records, id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, {:unknown_execution_policy, id}}
    end
  end

  def fetch(%__MODULE__{}, id), do: {:error, {:unknown_execution_policy, id}}

  @doc "Fetches a record from the built-in registry."
  @spec fetch(String.t()) :: {:ok, Record.t()} | {:error, term()}
  def fetch(id), do: fetch(new!(), id)

  @doc "Fetches a record and raises when the policy is unknown."
  @spec fetch!(t(), String.t()) :: Record.t()
  def fetch!(%__MODULE__{} = registry, id) do
    case fetch(registry, id) do
      {:ok, record} -> record
      {:error, reason} -> raise ArgumentError, "unknown execution policy: #{inspect(reason)}"
    end
  end

  @doc "Lists canonical registered IDs in stable order."
  @spec ids(t()) :: [String.t()]
  def ids(%__MODULE__{records: records}), do: records |> Map.keys() |> Enum.sort()

  @doc "Returns a public Jidoka profile resolver for this trusted registry."
  @spec resolver(t()) :: (String.t(), keyword() -> {:ok, Registration.t()} | {:error, term()})
  def resolver(%__MODULE__{} = registry) do
    fn id, _opts ->
      case fetch(registry, id) do
        {:ok, record} -> {:ok, record.registration}
        {:error, {:unknown_execution_policy, _id}} -> {:error, :unknown_profile}
      end
    end
  end

  defp build_record(id, class, root?, warning, opts) do
    adapter_id = Keyword.get(opts, :adapter_id, @adapter_id)
    adapter_version = Keyword.get(opts, :adapter_version, @adapter_version)
    adapter = Keyword.get(opts, :adapter, Jido.Console.Coding.Local.Adapter)
    profile_revision = Keyword.get(opts, :profile_revision, 1)
    maximum_limits = Keyword.get(opts, :maximum_limits, @maximum_limits)
    capability_ids = Keyword.get(opts, :capability_ids, @capability_ids)

    profile_subject = %{
      contract: "jido_console.execution_policy.security_profile.v1",
      profile_id: id,
      revision: profile_revision,
      adapter_id: adapter_id,
      required_isolation: :process,
      required_network: :disabled,
      required_workspace: :persistent,
      maximum_limits: maximum_limits,
      checkpoint_required: false,
      fork_required: false,
      retention: :ephemeral,
      class: class
    }

    with {:ok, profile} <-
           SecurityProfile.new(
             profile_id: id,
             revision: profile_revision,
             digest: ExecutionEnvironment.digest(profile_subject),
             adapter_id: adapter_id,
             required_isolation: :process,
             required_network: :disabled,
             required_workspace: :persistent,
             maximum_limits: maximum_limits,
             metadata: %{"console_class" => Atom.to_string(class)}
           ),
         {:ok, capabilities} <-
           AdapterCapabilities.new(
             adapter_id: adapter_id,
             adapter_version: adapter_version,
             isolations: [:process],
             networks: [:disabled],
             workspaces: [:persistent],
             limit_keys: maximum_limits |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
             capability_ids: capability_ids
           ),
         {:ok, registration} <-
           Registration.new(profile: profile, adapter: adapter, capabilities: capabilities),
         {:ok, request} <- PolicyRequest.new(profile_id: id),
         {:ok, selection} <-
           ProfileResolver.resolve(request, fn profile_id, _resolver_opts ->
             if profile_id == id, do: {:ok, registration}, else: {:error, :unknown_profile}
           end) do
      evidence = Record.build_evidence(id, profile, capabilities, registration, selection)

      {:ok,
       %Record{
         execution_policy_id: id,
         class: class,
         warning: warning,
         requires_workspace_root?: root?,
         policy_request: request,
         security_profile: profile,
         adapter_capabilities: capabilities,
         registration: registration,
         jidoka_selection: selection,
         registration_fingerprint: registration.fingerprint,
         evidence: evidence
       }}
    end
  end
end
