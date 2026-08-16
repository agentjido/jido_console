defmodule Jido.Console.Coding.Setup do
  @moduledoc "Trusted CLI selection and context for the removable Jidoka coding pack."

  alias Jido.Console.Coding.{ClientSetup, FileMentions, Local, Profile, ProviderOptions, Selection, WorkspaceConfig}
  alias Jido.Console.Extensions
  alias Jido.Console.Extensions.Setup, as: ExtensionSetup
  alias Jidoka.CodingPack
  alias Jidoka.CodingPack.{Instructions, Workspace}
  alias Jidoka.Extension.Request

  @default_pack CodingPack.id()

  @enforce_keys [
    :spec,
    :extension_setup,
    :workspace,
    :instructions,
    :context,
    :pack_id,
    :profile_id,
    :environment_contract,
    :local_resources,
    :await_timeout_ms,
    :turn_opts
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          spec: Jidoka.Agent.Spec.t(),
          extension_setup: Jido.Console.Extensions.Setup.t(),
          workspace: Workspace.t() | nil,
          instructions: [map()],
          context: map(),
          pack_id: String.t() | nil,
          profile_id: String.t() | nil,
          environment_contract: Jido.Console.Coding.Environment.Contract.t() | nil,
          local_resources: Local.Resources.t() | nil,
          await_timeout_ms: pos_integer(),
          turn_opts: keyword()
        }

  @doc "Resolves the trusted interactive coding setup."
  @spec prepare(module() | Jidoka.Agent.Spec.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def prepare(agent, opts) when is_list(opts) do
    with {:ok, spec} <- spec(agent),
         {:ok, selection} <- Selection.resolve(opts),
         :ok <- Selection.validate_profile(selection.profile_id, opts),
         {:ok, profile} <- Profile.resolve(selection.profile_id, opts),
         {:ok, spec} <- ProviderOptions.tune_spec(spec, selection, opts) do
      configure(spec, selection, profile, opts)
    end
  end

  @doc "Closes trusted local resources held by one resolved setup."
  @spec close(t()) :: :ok
  def close(%__MODULE__{local_resources: resources} = setup) do
    if setup.local_resources do
      _ = Jido.Console.Process.stop(Jido.Console.Process.spec(:coding_runtime).name)
    end

    Local.close(resources)
  end

  @doc "Returns the bounded coding context that attached clients can use."
  @spec client_setup(t()) :: ClientSetup.t()
  def client_setup(%__MODULE__{} = setup) do
    %ClientSetup{
      workspace: setup.workspace,
      instructions: setup.instructions,
      context: setup.context,
      await_timeout_ms: setup.await_timeout_ms,
      turn_opts: setup.turn_opts
    }
  end

  @doc "Resolves file mentions and returns portable Jidoka context data."
  @spec prepare_prompt(t(), String.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def prepare_prompt(%__MODULE__{workspace: nil, context: context}, prompt),
    do: {:ok, unescape(prompt), context}

  def prepare_prompt(%__MODULE__{workspace: workspace, context: context}, prompt) do
    with {:ok, prompt, files} <- FileMentions.resolve(workspace, prompt) do
      coding = context["coding"] |> Map.put("files", files)
      {:ok, prompt, put_in(context, ["coding"], coding)}
    end
  end

  def prepare_prompt(%ClientSetup{workspace: nil, context: context}, prompt),
    do: {:ok, unescape(prompt), context}

  def prepare_prompt(%ClientSetup{workspace: workspace, context: context}, prompt) do
    with {:ok, prompt, files} <- FileMentions.resolve(workspace, prompt) do
      coding = context["coding"] |> Map.put("files", files)
      {:ok, prompt, put_in(context, ["coding"], coding)}
    end
  end

  defp configure(spec, %{pack_id: nil}, _profile, opts) do
    extensions = Enum.reject(spec.extensions, &(&1.id == @default_pack))

    with {:ok, spec} <- Jidoka.Agent.Spec.new(spec |> Map.from_struct() |> Map.put(:extensions, extensions)),
         {:ok, extension_setup} <- Extensions.resolve(extensions, :interactive, opts) do
      {:ok,
       %__MODULE__{
         spec: spec,
         extension_setup: ExtensionSetup.disabled(extension_setup),
         workspace: nil,
         instructions: [],
         context: %{"coding" => %{"status" => "disabled"}},
         pack_id: nil,
         profile_id: nil,
         environment_contract: nil,
         local_resources: nil,
         await_timeout_ms: 30_000,
         turn_opts: []
       }}
    end
  end

  defp configure(spec, selection, profile, opts) do
    with {:ok, workspace} <- WorkspaceConfig.build(selection.profile_id, opts),
         {:ok, instructions} <- Instructions.discover(workspace, WorkspaceConfig.working_directory(opts)),
         {:ok, local} <- local_profile(selection.profile_id, workspace, profile.environment_contract) do
      finish_configuration(spec, selection, profile, workspace, instructions, local, opts)
    end
  end

  defp finish_configuration(spec, selection, profile, workspace, instructions, local, opts) do
    try do
      request = Request.new!(id: selection.pack_id)

      result =
        with {:ok, spec} <- put_request(spec, request),
             {:ok, extension_setup} <-
               extension_setup(selection.pack_id, spec.extensions, workspace, local, opts) do
          context = %{
            "coding" => %{
              "status" => "enabled",
              "profile" => Profile.to_map(profile),
              "pack_id" => selection.pack_id,
              "profile_id" => selection.profile_id,
              "workspace" => Workspace.to_map(workspace),
              "instructions" => instructions,
              "files" => []
            }
          }

          setup = %__MODULE__{
            spec: spec,
            extension_setup: extension_setup,
            workspace: workspace,
            instructions: instructions,
            context: context,
            pack_id: selection.pack_id,
            profile_id: selection.profile_id,
            environment_contract: profile.environment_contract,
            local_resources: Map.get(local, :resources),
            await_timeout_ms: if(Map.get(local, :resources), do: 180_000, else: 30_000),
            turn_opts: ProviderOptions.turn_opts(selection.profile_id, Jidoka.Config.model_ref(spec.model))
          }

          register_coding_runtime(setup, opts)
          {:ok, setup}
        end

      close_on_error(result, local)
    rescue
      exception ->
        Local.close(Map.get(local, :resources))
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        Local.close(Map.get(local, :resources))
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp register_coding_runtime(%__MODULE__{local_resources: %{manager: manager}}, opts)
       when is_pid(manager) do
    _ = Jido.Console.Process.register(:coding_runtime, manager, Keyword.take(opts, [:name, :jido_home]))
    :ok
  end

  defp register_coding_runtime(_setup, _opts), do: :ok

  defp close_on_error({:ok, _setup} = success, _local), do: success

  defp close_on_error({:error, _reason} = error, local) do
    Local.close(Map.get(local, :resources))
    error
  end

  defp extension_setup(@default_pack, requests, workspace, local, opts) do
    entry_opts =
      [
        mutation: Keyword.get(opts, :coding_mutation_port, Map.get(local, :mutation)),
        shell: Keyword.get(opts, :coding_shell_port, Map.get(local, :shell)),
        git: Keyword.get(opts, :coding_git_port, Map.get(local, :git)),
        verify: Keyword.get(opts, :coding_verify_port, Map.get(local, :verify)),
        replace_tools: Keyword.get(opts, :coding_replace_tools, %{}),
        disable_tools: Enum.uniq(Keyword.get(opts, :coding_disable_tools, []) ++ Map.get(local, :disable_tools, []))
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    other_requests = Enum.reject(requests, &(&1.id == @default_pack))

    with {:ok, entry} <- CodingPack.entry(workspace, entry_opts),
         {:ok, other_setup} <- Extensions.resolve(other_requests, :interactive, opts) do
      {:ok,
       ExtensionSetup.prepend(
         other_setup,
         entry,
         %{"id" => @default_pack, "source" => "built_in"},
         recover_coding_errors: Map.has_key?(local, :resources)
       )}
    end
  end

  defp extension_setup(_replacement, requests, _workspace, _local, opts),
    do: Extensions.resolve(requests, :interactive, opts)

  defp local_profile(nil, _workspace, nil), do: {:ok, %{}}

  defp local_profile(_profile_id, workspace, environment_contract) do
    case Local.prepare(workspace, environment_contract) do
      {:ok, _local} = success -> success
      {:error, :local_coding_executable_missing} -> {:ok, %{}}
      {:error, :local_coding_module_unavailable} -> {:ok, %{}}
      {:error, _reason} = error -> error
    end
  end

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

  defp unescape(prompt), do: String.replace(prompt, "\\@", "@")
end
