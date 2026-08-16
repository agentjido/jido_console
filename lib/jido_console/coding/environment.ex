defmodule Jido.Console.Coding.Environment do
  @moduledoc """
  Resolves and materializes the restricted process environment.

  Setup owns one secret-free contract. Credential values are resolved only when
  the local adapter materializes the process environment for a command.
  """

  alias Jido.Console.Coding.Environment.Contract
  alias Jido.Console.Coding.RestrictedProfile
  alias Jido.Console.Credentials
  alias Jido.Console.Env
  alias Jido.Console.Home

  @doc "Resolves one secret-free restricted environment contract."
  @spec resolve(String.t(), keyword()) :: {:ok, Contract.t()} | {:error, term()}
  def resolve(profile_id, opts \\ []) when is_binary(profile_id) and profile_id != "" do
    with {:ok, allowlist} <- allowlist(opts),
         {:ok, credential_refs} <- credential_refs(opts),
         :ok <- reject_credentials_in_allowlist(allowlist),
         {:ok, roots} <- ensure_roots(opts) do
      {:ok,
       %Contract{
         profile_id: profile_id,
         allowlist: allowlist,
         credential_refs: credential_refs,
         home: roots.home,
         tmpdir: roots.tmpdir
       }}
    end
  end

  @doc "Materializes one contract at the final local process boundary."
  @spec materialize(Contract.t(), keyword()) :: {:ok, map()}
  def materialize(%Contract{} = contract, opts \\ []) do
    host_env = Keyword.get_lazy(opts, :host_env, &System.get_env/0)

    env =
      contract.allowlist
      |> copy_allowlisted(host_env)
      |> put_credentials(contract.credential_refs, host_env)
      |> Map.put("HOME", contract.home)
      |> Map.put("TMPDIR", contract.tmpdir)

    {:ok, env}
  end

  @doc "Projects the secret-free contract for setup and execution evidence."
  @spec evidence(Contract.t()) :: map()
  def evidence(%Contract{} = contract) do
    %{
      "profile_id" => contract.profile_id,
      "allowlist" => contract.allowlist,
      "references" => contract.credential_refs,
      "home" => "private",
      "tmpdir" => "declared",
      "contract_digest" => digest(contract)
    }
  end

  @doc "Returns the stable digest that joins setup and execution evidence."
  @spec digest(Contract.t()) :: String.t()
  def digest(%Contract{} = contract) do
    Jidoka.ExecutionEnvironment.digest(%{
      profile_id: contract.profile_id,
      allowlist: contract.allowlist,
      credential_refs: contract.credential_refs,
      home: contract.home,
      tmpdir: contract.tmpdir
    })
  end

  defp allowlist(opts) do
    case Keyword.get(opts, :environment_allowlist, RestrictedProfile.environment_allowlist()) do
      list when is_list(list) and list != [] ->
        if Enum.all?(list, &(&1 != "" and is_binary(&1))),
          do: {:ok, Enum.uniq(list)},
          else: {:error, :invalid_environment_allowlist}

      _other ->
        {:error, :incomplete_environment_contract}
    end
  end

  defp credential_refs(opts) do
    case Keyword.get(opts, :credential_sources, []) do
      requested when is_list(requested) -> validate_credential_refs(requested)
      _invalid -> {:error, :invalid_credential_sources}
    end
  end

  defp validate_credential_refs(requested) do
    declared = Env.provider_keys()

    undeclared = Enum.reject(requested, &(&1 in declared))

    if undeclared == [] do
      {:ok, requested |> Enum.uniq() |> Enum.map(&("env:" <> &1))}
    else
      {:error, {:undeclared_credential_source, undeclared}}
    end
  end

  defp reject_credentials_in_allowlist(allowlist) do
    credential_keys = Enum.filter(allowlist, &(&1 in Env.provider_keys()))

    if credential_keys == [],
      do: :ok,
      else: {:error, {:credential_in_environment_allowlist, credential_keys}}
  end

  defp ensure_roots(opts) do
    with {:ok, _home} <- Home.ensure(opts),
         {:ok, cache} <- Home.path(:cache, opts),
         roots = %{
           home: Path.join(cache, "restricted-home"),
           tmpdir: Path.join(cache, "restricted-tmp")
         },
         :ok <- mkdir_private(roots.home),
         :ok <- mkdir_private(roots.tmpdir) do
      {:ok, roots}
    end
  end

  defp copy_allowlisted(allowlist, source) do
    allowlist
    |> Enum.reduce(%{}, fn key, env ->
      if present?(Map.get(source, key)), do: Map.put(env, key, Map.fetch!(source, key)), else: env
    end)
  end

  defp put_credentials(env, refs, host_env) do
    variables = Enum.map(refs, &String.replace_prefix(&1, "env:", ""))

    variables
    |> Credentials.resolve_all(host_env, %{})
    |> Enum.reduce(env, fn credential, materialized ->
      Map.put(materialized, credential.variable, credential.value)
    end)
  end

  defp mkdir_private(path) do
    with :ok <- File.mkdir_p(path) do
      File.chmod(path, Home.directory_mode())
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
