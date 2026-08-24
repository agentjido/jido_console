defmodule Jido.Console.Coding.Setup do
  @moduledoc "Post-lock coding resource setup for one immutable session binding."

  alias Jido.Console.AgentSource
  alias Jido.Console.AgentSource.Record, as: SourceRecord
  alias Jido.Console.Coding.{ClientSetup, Environment, FileMentions, Local, Pack, ProviderOptions, WorkspaceConfig}
  alias Jido.Console.Digest
  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.Extensions
  alias Jido.Console.Extensions.Setup, as: ExtensionSetup
  alias Jido.Console.Session.Binding
  alias Jidoka.CodingPack
  alias Jidoka.CodingPack.{Instructions, Workspace}

  @pack_id Jidoka.CodingPack.id()

  @schema Zoi.struct(
            __MODULE__,
            %{
              binding: Zoi.any(),
              spec: Zoi.struct(Jidoka.Agent.Spec),
              extension_setup: Zoi.any(),
              workspace: Zoi.struct(Workspace) |> Zoi.nullable(),
              instructions: Zoi.array(Zoi.map()),
              context: Zoi.map(),
              pack_id: Zoi.string() |> Zoi.nullable(),
              execution_policy_id: Zoi.string(),
              profile_id: Zoi.string(),
              environment_contract: Zoi.any(),
              local_resources: Zoi.any(),
              runtime_definition_fingerprint: Zoi.string(),
              await_timeout_ms: Zoi.integer() |> Zoi.positive(),
              turn_opts: Zoi.list(Zoi.tuple({Zoi.atom(), Zoi.any()}))
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type t :: %__MODULE__{
          binding: Binding.t(),
          spec: Jidoka.Agent.Spec.t(),
          extension_setup: ExtensionSetup.t(),
          workspace: Workspace.t() | nil,
          instructions: [map()],
          context: map(),
          pack_id: String.t() | nil,
          execution_policy_id: String.t(),
          profile_id: String.t(),
          environment_contract: Jido.Console.Coding.Environment.Contract.t() | nil,
          local_resources: Local.Resources.t() | nil,
          runtime_definition_fingerprint: String.t(),
          await_timeout_ms: pos_integer(),
          turn_opts: keyword()
        }

  @doc "Opens trusted runtime resources from a bound semantic specification."
  @spec prepare(Binding.t() | module() | Jidoka.Agent.Spec.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def prepare(input, opts) when is_list(opts) do
    with {:ok, binding} <- resolve_binding(input, opts),
         {:ok, spec} <- ProviderOptions.tune_spec(binding, opts) do
      configure(binding, spec, opts)
    end
  end

  @doc "Resolves one semantic binding without opening runtime resources."
  @spec resolve_binding(Binding.t() | module() | Jidoka.Agent.Spec.t() | String.t(), keyword()) ::
          {:ok, Binding.t()} | {:needs_model, map()} | {:error, term()}
  def resolve_binding(input, opts \\ []) when is_list(opts), do: binding(input, opts)

  @doc "Closes trusted local resources held by one resolved setup."
  @spec close(t()) :: :ok
  def close(%__MODULE__{local_resources: resources}), do: Local.close(resources)

  @doc "Returns the bounded coding context that attached clients can use."
  @spec client_setup(t()) :: ClientSetup.t()
  def client_setup(%__MODULE__{} = setup) do
    %ClientSetup{
      workspace: setup.workspace,
      instructions: setup.instructions,
      context: setup.context,
      pack_id: setup.pack_id,
      execution_policy_id: setup.execution_policy_id,
      await_timeout_ms: setup.await_timeout_ms,
      turn_opts: setup.turn_opts
    }
  end

  @doc "Resolves file mentions and returns portable Jidoka context data."
  @spec prepare_prompt(t() | ClientSetup.t(), String.t()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def prepare_prompt(%{workspace: nil, context: context}, prompt),
    do: {:ok, unescape(prompt), context}

  def prepare_prompt(%{workspace: %Workspace{} = workspace, context: context}, prompt) do
    with {:ok, prompt, files} <- FileMentions.resolve(workspace, prompt) do
      coding = context["coding"] |> Map.put("files", files)
      {:ok, prompt, put_in(context, ["coding"], coding)}
    end
  end

  defp configure(%Binding{pack: %Pack{state: :disabled}} = binding, spec, opts) do
    with {:ok, extension_setup} <- Extensions.resolve(spec.extensions, opts),
         {:ok, extension_setup} <-
           ExtensionSetup.with_runtime_definition(extension_setup, binding.runtime_definition),
         {:ok, provider_opts} <- ProviderOptions.runtime_opts(binding, opts) do
      {:ok,
       %__MODULE__{
         binding: binding,
         spec: spec,
         extension_setup: ExtensionSetup.disabled(extension_setup),
         workspace: nil,
         instructions: [],
         context:
           Map.put(binding.safe_context, "coding", %{
             "status" => "disabled",
             "pack_id" => nil,
             "execution_policy_id" => binding.execution_policy.execution_policy_id,
             "workspace_identity_digest" => workspace_digest(binding.workspace),
             "files" => []
           }),
         pack_id: nil,
         execution_policy_id: binding.execution_policy.execution_policy_id,
         profile_id: binding.execution_policy.execution_policy_id,
         environment_contract: nil,
         local_resources: nil,
         runtime_definition_fingerprint: binding.runtime_definition_fingerprint,
         await_timeout_ms: 30_000,
         turn_opts: provider_opts
       }}
    end
  end

  defp configure(%Binding{} = binding, spec, opts) do
    policy = binding.execution_policy

    with {:ok, workspace} <- WorkspaceConfig.build(policy.execution_policy_id, opts),
         :ok <- validate_workspace(binding.workspace, workspace),
         {:ok, instructions} <-
           Instructions.discover(workspace, WorkspaceConfig.working_directory(opts)),
         {:ok, environment_contract} <- Environment.resolve(policy.execution_policy_id, opts),
         {:ok, local} <- Local.prepare(policy.record, workspace, environment_contract) do
      finish_configuration(binding, spec, workspace, instructions, environment_contract, local, opts)
    end
  end

  defp finish_configuration(binding, spec, workspace, instructions, environment_contract, local, opts) do
    try do
      result =
        with {:ok, extension_setup} <-
               extension_setup(binding.pack, spec.extensions, workspace, local, opts),
             {:ok, extension_setup} <-
               ExtensionSetup.with_runtime_definition(extension_setup, binding.runtime_definition),
             {:ok, provider_opts} <- ProviderOptions.runtime_opts(binding, opts) do
          context =
            Map.put(binding.safe_context, "coding", %{
              "status" => "enabled",
              "pack_id" => binding.pack.id,
              "execution_policy_id" => binding.execution_policy.execution_policy_id,
              "workspace_identity_digest" => workspace_digest(binding.workspace),
              "workspace" => Workspace.to_map(workspace),
              "instructions" => instructions,
              "files" => []
            })

          policy_turn_opts =
            ProviderOptions.turn_opts(
              binding.execution_policy.execution_policy_id,
              binding.model_id
            )

          {:ok,
           %__MODULE__{
             binding: binding,
             spec: spec,
             extension_setup: extension_setup,
             workspace: workspace,
             instructions: instructions,
             context: context,
             pack_id: binding.pack.id,
             execution_policy_id: binding.execution_policy.execution_policy_id,
             profile_id: binding.execution_policy.execution_policy_id,
             environment_contract: environment_contract,
             local_resources: local.resources,
             runtime_definition_fingerprint: binding.runtime_definition_fingerprint,
             await_timeout_ms: 180_000,
             turn_opts: Keyword.merge(policy_turn_opts, provider_opts)
           }}
        end

      close_on_error(result, local)
    rescue
      exception ->
        Local.close(local.resources)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        Local.close(local.resources)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp close_on_error({:ok, _setup} = success, _local), do: success

  defp close_on_error({:error, _reason} = error, local) do
    Local.close(local.resources)
    error
  end

  defp extension_setup(%Pack{id: id}, requests, workspace, local, opts)
       when id == @pack_id do
    entry_opts =
      [
        mutation: local.mutation,
        shell: local.shell,
        git: local.git,
        verify: local.verify,
        replace_tools: Keyword.get(opts, :coding_replace_tools, %{}),
        disable_tools: Enum.uniq(Keyword.get(opts, :coding_disable_tools, []) ++ local.disable_tools)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    other_requests = Enum.reject(requests, &(&1.id == @pack_id))

    with {:ok, entry} <- CodingPack.entry(workspace, entry_opts),
         {:ok, other_setup} <- Extensions.resolve(other_requests, opts) do
      {:ok,
       ExtensionSetup.prepend(
         other_setup,
         entry,
         %{"id" => @pack_id, "source" => "built_in"},
         recover_coding_errors: true
       )}
    end
  end

  defp extension_setup(_pack, requests, _workspace, _local, opts),
    do: Extensions.resolve(requests, opts)

  defp binding(%Binding{} = binding, _opts), do: {:ok, binding}

  defp binding(agent, opts) do
    with {:ok, source} <- source_record(agent, opts),
         {:ok, pack} <- Pack.resolve(opts),
         {:ok, direct_choice} <- direct_policy_choice(opts),
         {:ok, policy} <- policy_selection(source.base_spec, direct_choice, opts) do
      model_choice =
        if Keyword.has_key?(opts, :model) do
          %{id: Keyword.fetch!(opts, :model), origin: Keyword.get(opts, :model_origin, :api)}
        end

      Binding.build(source, pack, model_choice, policy, policy.workspace,
        workspace_configuration: workspace_configuration(opts),
        runtime_definition: Pack.runtime_definition(pack, opts)
      )
    end
  end

  defp source_record(agent, _opts) when agent in [Jido.Console.Agents.Default, Jido.Console.DefaultAgent],
    do: AgentSource.resolve("builtin:jido")

  defp source_record(agent, opts) when is_binary(agent), do: AgentSource.resolve(agent, opts)

  defp source_record(agent, _opts) do
    case Jidoka.Agent.Spec.from_input(agent) do
      {:ok, spec} -> {:ok, compiled_source_record(spec)}
      {:error, _reason} -> {:error, :invalid_coding_agent}
    end
  end

  defp compiled_source_record(spec) do
    projection = Jidoka.project(spec)
    identity = "compiled:" <> spec.id
    source_bytes = Digest.semantic_bytes(:compiled_agent_source, projection)

    SourceRecord.build(
      base_spec: spec,
      identity: identity,
      kind: :builtin,
      format: :compiled,
      byte_size: byte_size(source_bytes),
      digest: Digest.portable(source_bytes),
      base_spec_digest: Digest.semantic(:agent_base_spec, projection),
      agent_id: spec.id,
      label: spec.id
    )
  end

  defp direct_policy_choice(opts) do
    if Keyword.has_key?(opts, :execution_policy) or Keyword.has_key?(opts, :coding_profile),
      do: ExecutionPolicy.direct_choice(opts, :api),
      else: {:ok, nil}
  end

  defp policy_selection(spec, direct_choice, opts) do
    selection_opts = [
      agent_request: spec.execution_profile,
      direct_choice: direct_choice,
      project_root: Keyword.get(opts, :project_root)
    ]

    selection_opts =
      case Keyword.fetch(opts, :execution_policy_registry) do
        {:ok, registry} -> Keyword.put(selection_opts, :registry, registry)
        :error -> selection_opts
      end

    ExecutionPolicy.resolve(selection_opts)
  end

  defp workspace_configuration(opts) do
    %{
      "working_directory" => WorkspaceConfig.working_directory(opts),
      "access" => Keyword.get(opts, :coding_access),
      "limits" => Keyword.get(opts, :coding_limits)
    }
  end

  defp validate_workspace(nil, _workspace), do: :ok

  defp validate_workspace(identity, %Workspace{root: root}) do
    case File.stat(root) do
      {:ok, stat} ->
        if field(identity, :major_device) == stat.major_device and
             field(identity, :minor_device) == stat.minor_device and
             field(identity, :inode) == stat.inode,
           do: :ok,
           else: {:error, :workspace_identity_mismatch}

      {:error, _reason} ->
        {:error, :workspace_identity_mismatch}
    end
  end

  defp workspace_digest(nil), do: nil
  defp workspace_digest(workspace), do: field(workspace, :digest)

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp unescape(prompt), do: String.replace(prompt, "\\@", "@")
end
