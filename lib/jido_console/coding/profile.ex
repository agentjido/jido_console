defmodule Jido.Console.Coding.Profile do
  @moduledoc """
  Deprecated compatibility facade for `Jido.Console.ExecutionPolicy`.

  This module keeps the release-line coding setup shape. New selection code
  must use the execution-policy registry and selector.
  """

  alias Jido.Console.Coding.Environment
  alias Jido.Console.Coding.Environment.Contract
  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.Home

  @version 1
  @deprecation "Use Jido.Console.ExecutionPolicy"

  @type t :: %{
          id: String.t() | nil,
          execution_policy_id: String.t() | nil,
          version: pos_integer(),
          class: :restricted | :trusted_workspace,
          explicit?: boolean(),
          sandbox?: false,
          warning: String.t() | nil,
          enforcement: :pending | :reported,
          environment_contract: Contract.t() | nil,
          roots: map()
        }

  @deprecated @deprecation
  @doc "Returns the default restricted execution-policy identifier."
  @spec restricted_id() :: String.t()
  def restricted_id, do: ExecutionPolicy.restricted_id()

  @deprecated @deprecation
  @doc "Returns the canonical trusted-workspace execution-policy identifier."
  @spec trusted_id() :: String.t()
  def trusted_id, do: ExecutionPolicy.trusted_id()

  @deprecated @deprecation
  @doc "Returns the trusted-workspace warning."
  @spec trusted_warning() :: String.t()
  def trusted_warning, do: ExecutionPolicy.trusted_warning()

  @deprecated @deprecation
  @doc "Returns true for the canonical trusted ID or its local alias."
  @spec trusted?(String.t() | nil) :: boolean()
  def trusted?(id), do: ExecutionPolicy.normalize_id(id) == ExecutionPolicy.trusted_id()

  @deprecated @deprecation
  @doc "Returns true only when this input layer contains a direct choice."
  @spec explicit_choice?(keyword()) :: boolean()
  def explicit_choice?(opts) do
    Keyword.has_key?(opts, :execution_policy) or Keyword.has_key?(opts, :coding_profile)
  end

  @deprecated @deprecation
  @doc "Resolves one compatibility profile through the canonical selector."
  @spec resolve(String.t() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(nil, _opts), do: {:ok, disabled()}

  def resolve(execution_policy_id, opts) when is_binary(execution_policy_id) and is_list(opts) do
    with {:ok, direct} <- compatibility_direct_choice(opts),
         {:ok, selection} <-
           ExecutionPolicy.resolve(
             agent_request: execution_policy_id,
             direct_choice: direct,
             project_root: Keyword.get(opts, :project_root)
           ),
         {:ok, contract} <- Environment.resolve(selection.execution_policy_id, opts),
         {:ok, roots} <- roots(selection.execution_policy_id, contract, opts) do
      {:ok, compatibility_map(selection, contract, roots, opts)}
    end
  end

  def resolve(execution_policy_id, _opts),
    do: {:error, {:unknown_execution_policy, execution_policy_id}}

  @deprecated @deprecation
  @doc "Returns true when restricted boundary adapters reported enforcement."
  @spec restricted_passed?(t()) :: boolean()
  def restricted_passed?(%{class: :restricted, enforcement: :reported}), do: true
  def restricted_passed?(_profile), do: false

  @deprecated @deprecation
  @doc "Projects the compatibility value with canonical policy evidence keys."
  @spec to_map(t()) :: map()
  def to_map(profile) do
    %{
      "execution_policy_id" => profile.execution_policy_id,
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

  defp compatibility_direct_choice(opts) do
    if explicit_choice?(opts),
      do: ExecutionPolicy.direct_choice(opts, :api),
      else: {:ok, nil}
  end

  defp compatibility_map(selection, contract, roots, opts) do
    restricted? = selection.execution_policy_id == ExecutionPolicy.restricted_id()

    %{
      id: selection.execution_policy_id,
      execution_policy_id: selection.execution_policy_id,
      version: @version,
      class: selection.record.class,
      explicit?: selection.origin in [:cli, :api, :tui],
      sandbox?: false,
      warning: selection.warning,
      enforcement: if(restricted?, do: Keyword.get(opts, :restricted_enforcement, :pending), else: :reported),
      environment_contract: contract,
      roots: roots
    }
  end

  defp roots(id, %Contract{} = contract, opts) do
    if id == ExecutionPolicy.restricted_id() do
      restricted_roots(contract, opts)
    else
      {:ok,
       %{
         "workspace" => Keyword.get(opts, :project_root),
         "temporary" => contract.tmpdir,
         "home" => contract.home
       }}
    end
  end

  defp restricted_roots(%Contract{} = contract, opts) do
    with {:ok, artifacts} <- Home.path(:artifacts, opts) do
      {:ok,
       %{
         "workspace" => Keyword.get(opts, :project_root, File.cwd!()),
         "toolchain" => System.find_executable("mix") || "mix",
         "artifact" => artifacts,
         "temporary" => contract.tmpdir,
         "home" => contract.home
       }}
    end
  end

  defp disabled do
    %{
      id: nil,
      execution_policy_id: nil,
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

  defp root_presence(roots) when is_map(roots) do
    Map.new(roots, fn {key, value} ->
      {key, if(value in [nil, ""], do: "missing", else: "declared")}
    end)
  end

  defp environment_evidence(nil), do: %{}
  defp environment_evidence(%Contract{} = contract), do: Environment.evidence(contract)
end
