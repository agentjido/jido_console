defmodule Jido.Console.Coding.Environment do
  @moduledoc """
  Builds the restricted process environment: allowlisted keys and a private HOME.

  Credential values are never copied into arguments or evidence. Only declared
  credential references may be present, and temporary files stay under Jido home.
  """

  alias Jido.Console.Auth
  alias Jido.Console.Coding.RestrictedProfile
  alias Jido.Console.Home

  @type manifest :: %{
          profile_id: String.t(),
          allowlist: [String.t()],
          home: String.t(),
          tmpdir: String.t(),
          credential_refs: [String.t()],
          keys: [String.t()]
        }

  @doc "Constructs a restricted environment or rejects an invalid contract."
  @spec build(keyword()) :: {:ok, %{env: map(), manifest: manifest()}} | {:error, term()}
  def build(opts \\ []) do
    with {:ok, allowlist} <- allowlist(opts),
         :ok <- reject_undeclared_credentials(opts),
         {:ok, roots} <- ensure_roots(opts),
         env <- materialize(allowlist, roots, opts) do
      {:ok,
       %{
         env: env,
         manifest: %{
           profile_id: Keyword.get(opts, :profile_id, RestrictedProfile.id()),
           allowlist: allowlist,
           home: "private",
           tmpdir: "declared",
           credential_refs: credential_refs(opts),
           keys: env |> Map.keys() |> Enum.sort()
         }
       }}
    end
  end

  @doc "Returns the default restricted environment allowlist."
  @spec default_allowlist() :: [String.t()]
  def default_allowlist, do: RestrictedProfile.environment_allowlist()

  @doc "Returns the private HOME and TMPDIR paths for restricted execution."
  @spec declared_roots(keyword()) :: {:ok, %{home: String.t(), tmpdir: String.t()}} | {:error, term()}
  def declared_roots(opts \\ []) do
    with {:ok, _home} <- Home.ensure(opts),
         {:ok, cache} <- Home.path(:cache, opts) do
      {:ok,
       %{
         home: Path.join(cache, "restricted-home"),
         tmpdir: Path.join(cache, "restricted-tmp")
       }}
    end
  end

  defp allowlist(opts) do
    case Keyword.get(opts, :allowlist, RestrictedProfile.environment_allowlist()) do
      list when is_list(list) and list != [] ->
        if Enum.all?(list, &(&1 != "" and is_binary(&1))),
          do: {:ok, Enum.uniq(list)},
          else: {:error, :invalid_environment_allowlist}

      _other ->
        {:error, :incomplete_environment_contract}
    end
  end

  defp reject_undeclared_credentials(opts) do
    requested = Keyword.get(opts, :credential_sources, [])
    declared = Auth.sources() |> Map.values() |> List.flatten() |> Enum.map(& &1.variable)

    undeclared = Enum.reject(requested, &(&1 in declared))

    if undeclared == [], do: :ok, else: {:error, {:undeclared_credential_source, undeclared}}
  end

  defp ensure_roots(opts) do
    with {:ok, roots} <- declared_roots(opts),
         :ok <- mkdir_private(roots.home),
         :ok <- mkdir_private(roots.tmpdir) do
      {:ok, roots}
    end
  end

  defp materialize(allowlist, roots, opts) do
    source = Keyword.get_lazy(opts, :host_env, &System.get_env/0)

    allowlist
    |> Enum.reduce(%{}, fn key, env ->
      if present?(Map.get(source, key)), do: Map.put(env, key, Map.fetch!(source, key)), else: env
    end)
    |> Map.put("HOME", roots.home)
    |> Map.put("TMPDIR", roots.tmpdir)
  end

  defp credential_refs(opts) do
    opts
    |> Keyword.get(:credential_sources, [])
    |> Enum.map(&("env:" <> &1))
  end

  defp mkdir_private(path) do
    with :ok <- File.mkdir_p(path) do
      File.chmod(path, Home.directory_mode())
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
