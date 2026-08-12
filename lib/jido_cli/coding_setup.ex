defmodule Jido.Cli.CodingSetup do
  @moduledoc "Trusted CLI selection and context for the removable Jidoka coding pack."

  alias Jido.Cli.Extensions
  alias Jidoka.CodingPack
  alias Jidoka.CodingPack.{Instructions, Workspace}
  alias Jidoka.Extension.Request

  @default_pack CodingPack.id()
  @default_profile "coding.default"

  @type t :: %{
          spec: Jidoka.Agent.Spec.t(),
          extension_setup: map(),
          workspace: Workspace.t() | nil,
          instructions: [map()],
          context: map(),
          pack_id: String.t() | nil,
          profile_id: String.t() | nil
        }

  @doc "Resolves the trusted interactive coding setup."
  @spec prepare(module() | Jidoka.Agent.Spec.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def prepare(agent, opts) when is_list(opts) do
    with {:ok, spec} <- spec(agent),
         {:ok, selection} <- selection(opts),
         {:ok, setup} <- configure(spec, selection, opts) do
      {:ok, setup}
    end
  end

  @doc "Resolves file mentions and returns portable Jidoka context data."
  @spec prepare_prompt(t(), String.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def prepare_prompt(%{workspace: nil, context: context}, prompt), do: {:ok, unescape(prompt), context}

  def prepare_prompt(%{workspace: workspace, context: context}, prompt) do
    with {:ok, prompt, files} <- Jido.Cli.FileMentions.resolve(workspace, prompt) do
      coding = context["coding"] |> Map.put("files", files)
      {:ok, prompt, put_in(context, ["coding"], coding)}
    end
  end

  defp configure(spec, %{pack_id: nil}, opts) do
    extensions = Enum.reject(spec.extensions, &(&1.id == @default_pack))

    with {:ok, spec} <- Jidoka.Agent.Spec.new(spec |> Map.from_struct() |> Map.put(:extensions, extensions)),
         {:ok, extension_setup} <- Extensions.resolve(extensions, :interactive, opts) do
      {:ok,
       %{
         spec: spec,
         extension_setup: %{
           extension_setup
           | projection: %{
               "status" => "disabled",
               "other_extensions" => extension_setup.projection
             }
         },
         workspace: nil,
         instructions: [],
         context: %{"coding" => %{"status" => "disabled"}},
         pack_id: nil,
         profile_id: nil
       }}
    end
  end

  defp configure(spec, selection, opts) do
    with :ok <- validate_profile(selection.profile_id, opts),
         {:ok, workspace} <- workspace(selection.profile_id, opts),
         {:ok, instructions} <- Instructions.discover(workspace, working_directory(opts)),
         request = Request.new!(id: selection.pack_id),
         {:ok, spec} <- put_request(spec, request),
         {:ok, extension_setup} <- extension_setup(selection.pack_id, spec.extensions, workspace, opts) do
      context = %{
        "coding" => %{
          "status" => "enabled",
          "pack_id" => selection.pack_id,
          "profile_id" => selection.profile_id,
          "workspace" => Workspace.to_map(workspace),
          "instructions" => instructions,
          "files" => []
        }
      }

      {:ok,
       %{
         spec: spec,
         extension_setup: extension_setup,
         workspace: workspace,
         instructions: instructions,
         context: context,
         pack_id: selection.pack_id,
         profile_id: selection.profile_id
       }}
    end
  end

  defp extension_setup(@default_pack, requests, workspace, opts) do
    entry_opts =
      [
        mutation: Keyword.get(opts, :coding_mutation_port),
        shell: Keyword.get(opts, :coding_shell_port),
        git: Keyword.get(opts, :coding_git_port),
        verify: Keyword.get(opts, :coding_verify_port),
        replace_tools: Keyword.get(opts, :coding_replace_tools, %{}),
        disable_tools: Keyword.get(opts, :coding_disable_tools, [])
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    other_requests = Enum.reject(requests, &(&1.id == @default_pack))

    with {:ok, entry} <- CodingPack.entry(workspace, entry_opts),
         {:ok, other_setup} <- Extensions.resolve(other_requests, :interactive, opts) do
      {:ok,
       %{
         registry: Map.put(other_setup.registry, @default_pack, entry),
         projection: %{
           "status" => "trusted",
           "records" =>
             [%{"id" => @default_pack, "source" => "built_in"}] ++
               Map.get(other_setup.projection, "records", [])
         }
       }}
    end
  end

  defp extension_setup(_replacement, requests, _workspace, opts),
    do: Extensions.resolve(requests, :interactive, opts)

  defp workspace(profile_id, opts) do
    Workspace.new(
      root: Keyword.get(opts, :project_root, Application.get_env(:jido_cli, :project_root, File.cwd!())),
      access: Keyword.get(opts, :coding_access, Application.get_env(:jido_cli, :coding_access, [:read])),
      limits: Keyword.get(opts, :coding_limits, Application.get_env(:jido_cli, :coding_limits, %{})),
      execution_profile: profile_id
    )
  end

  defp selection(opts) do
    pack = Keyword.get(opts, :coding_pack, Application.get_env(:jido_cli, :coding_pack, @default_pack))
    profile = Keyword.get(opts, :coding_profile, Application.get_env(:jido_cli, :coding_profile, @default_profile))

    cond do
      pack in [false, :disabled, "disabled", nil] -> {:ok, %{pack_id: nil, profile_id: nil}}
      not (is_binary(pack) and pack != "") -> {:error, {:invalid_coding_pack, pack}}
      not (is_binary(profile) and profile != "") -> {:error, {:invalid_execution_profile, profile}}
      module_name?(pack) or module_name?(profile) -> {:error, :coding_module_name_forbidden}
      true -> {:ok, %{pack_id: pack, profile_id: profile}}
    end
  end

  defp validate_profile(profile_id, opts) do
    case Keyword.get(opts, :coding_profile_resolver, Application.get_env(:jido_cli, :coding_profile_resolver)) do
      nil -> :ok
      resolver when is_function(resolver, 1) -> normalize_profile_result(resolver.(profile_id), profile_id)
      _resolver -> {:error, :invalid_coding_profile_resolver}
    end
  end

  defp normalize_profile_result({:ok, _profile}, _id), do: :ok
  defp normalize_profile_result(:ok, _id), do: :ok
  defp normalize_profile_result({:error, reason}, id), do: {:error, {:unknown_runtime_profile, id, reason}}
  defp normalize_profile_result(_result, id), do: {:error, {:unknown_runtime_profile, id}}

  defp put_request(spec, request) do
    extensions = [request | Enum.reject(spec.extensions, &(&1.id == request.id))]
    Jidoka.Agent.Spec.new(spec |> Map.from_struct() |> Map.put(:extensions, extensions))
  end

  defp spec(agent) when is_atom(agent) do
    if Code.ensure_loaded?(agent) and function_exported?(agent, :spec, 0),
      do: {:ok, agent.spec()},
      else: {:error, :invalid_coding_agent}
  end

  defp spec(%Jidoka.Agent.Spec{} = spec), do: {:ok, spec}
  defp spec(_agent), do: {:error, :invalid_coding_agent}

  defp module_name?(value), do: String.starts_with?(value, ["Elixir.", ":"]) or String.contains?(value, "/")
  defp unescape(prompt), do: String.replace(prompt, "\\@", "@")

  defp working_directory(opts),
    do: Keyword.get(opts, :coding_working_directory, Application.get_env(:jido_cli, :coding_working_directory, "."))
end
