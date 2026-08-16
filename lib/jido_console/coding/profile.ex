defmodule Jido.Console.Coding.Profile do
  @moduledoc """
  Local execution-profile contract for Milestone 1.

  Restricted execution is the default coding profile. Trusted-workspace mode
  is an explicit option, is labelled as not a sandbox, and is excluded from
  the restricted-execution gate.
  """

  alias Jido.Console.Coding.{Environment, RestrictedProfile}
  alias Jido.Console.Coding.Environment.Contract
  alias Jido.Console.Home

  @trusted_id "coding.trusted-workspace"
  @version 1

  @type t :: %{
          id: String.t(),
          version: pos_integer(),
          class: :restricted | :trusted_workspace,
          explicit?: boolean(),
          sandbox?: false,
          warning: String.t() | nil,
          enforcement: :pending | :reported,
          environment_contract: Contract.t() | nil,
          roots: map()
        }

  @doc "Returns the default restricted profile identifier."
  @spec restricted_id() :: String.t()
  def restricted_id, do: RestrictedProfile.id()

  @doc "Returns the explicit trusted-workspace profile identifier."
  @spec trusted_id() :: String.t()
  def trusted_id, do: @trusted_id

  @doc "Returns the trusted-workspace warning."
  @spec trusted_warning() :: String.t()
  def trusted_warning, do: "Trusted-workspace mode is not a sandbox."

  @doc "Returns true when the profile is the explicit trusted-workspace option."
  @spec trusted?(String.t() | nil) :: boolean()
  def trusted?(id) when id in [@trusted_id, "coding.local"], do: true
  def trusted?(_id), do: false

  @doc "Returns true when a less-restricted profile was explicitly selected."
  @spec explicit_choice?(keyword()) :: boolean()
  def explicit_choice?(opts) do
    Keyword.has_key?(opts, :coding_profile) or
      Application.get_env(:jido_console, :coding_profile) != nil
  end

  @doc "Resolves the effective profile for one coding setup."
  @spec resolve(String.t() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(nil, _opts), do: {:ok, disabled()}

  def resolve(profile_id, opts) when is_binary(profile_id) do
    cond do
      profile_id == RestrictedProfile.id() ->
        restricted(opts, explicit?: selected?(opts, RestrictedProfile.id()))

      known_trusted?(profile_id) ->
        if selected?(opts, profile_id) do
          trusted(profile_id, opts)
        else
          {:error, {:explicit_profile_required, profile_id}}
        end

      true ->
        {:error, {:unknown_execution_profile, profile_id}}
    end
  end

  @doc "Returns true when restricted boundary adapters have reported enforcement."
  @spec restricted_passed?(t()) :: boolean()
  def restricted_passed?(%{class: :restricted, enforcement: :reported}), do: true
  def restricted_passed?(_profile), do: false

  @doc "Projects the effective profile for display and run records."
  @spec to_map(t()) :: map()
  def to_map(profile) do
    %{
      "id" => profile.id,
      "version" => profile.version,
      "class" => Atom.to_string(profile.class),
      "explicit" => profile.explicit?,
      "sandbox" => profile.sandbox?,
      "warning" => profile.warning,
      "enforcement" => Atom.to_string(profile.enforcement),
      "environment" => environment_evidence(profile.environment_contract),
      "roots" => root_presence(profile.roots)
    }
  end

  defp restricted(opts, extra) do
    with {:ok, contract} <- Environment.resolve(RestrictedProfile.id(), opts),
         {:ok, roots} <- restricted_roots(contract, opts) do
      {:ok,
       %{
         id: RestrictedProfile.id(),
         version: @version,
         class: :restricted,
         explicit?: extra[:explicit?],
         sandbox?: false,
         warning: nil,
         enforcement: Keyword.get(opts, :restricted_enforcement, :pending),
         environment_contract: contract,
         roots: roots
       }}
    end
  end

  defp trusted(profile_id, opts) do
    with {:ok, contract} <- Environment.resolve(profile_id, opts) do
      {:ok,
       %{
         id: profile_id,
         version: @version,
         class: :trusted_workspace,
         explicit?: true,
         sandbox?: false,
         warning: trusted_warning(),
         enforcement: :reported,
         environment_contract: contract,
         roots: %{
           "workspace" => Keyword.get(opts, :project_root),
           "temporary" => contract.tmpdir,
           "home" => contract.home
         }
       }}
    end
  end

  defp disabled do
    %{
      id: nil,
      version: @version,
      class: :restricted,
      explicit?: false,
      sandbox?: false,
      warning: nil,
      enforcement: :pending,
      environment_contract: nil,
      roots: %{}
    }
  end

  defp restricted_roots(%Contract{} = contract, opts) do
    with {:ok, artifacts} <- Home.path(:artifacts, opts) do
      workspace = Keyword.get(opts, :project_root, File.cwd!())

      {:ok,
       %{
         "workspace" => workspace,
         "toolchain" => System.find_executable("mix") || "mix",
         "artifact" => artifacts,
         "temporary" => contract.tmpdir,
         "home" => contract.home
       }}
    end
  end

  defp known_trusted?(id), do: trusted?(id)

  defp selected?(opts, profile_id) do
    Keyword.get(opts, :coding_profile, Application.get_env(:jido_console, :coding_profile)) == profile_id
  end

  defp root_presence(roots) when is_map(roots) do
    Map.new(roots, fn {key, value} -> {key, if(value in [nil, ""], do: "missing", else: "declared")} end)
  end

  defp environment_evidence(nil), do: %{}
  defp environment_evidence(%Contract{} = contract), do: Environment.evidence(contract)
end
