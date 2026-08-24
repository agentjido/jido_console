defmodule Jido.Console.Session.Binding do
  @moduledoc "Pure semantic binding of agent, pack, model, policy, and workspace inputs."

  alias Jido.Console.AgentSource.Record, as: SourceRecord
  alias Jido.Console.Coding.Pack
  alias Jido.Console.Digest
  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.ExecutionPolicy.{Record, Selection}
  alias Jido.Console.Extensions.Setup, as: ExtensionSetup
  alias Jido.Console.Models.Commands, as: ModelCommands
  alias Jidoka.Agent.Spec
  alias Jidoka.Agent.Spec.Memory

  @max_model_turns 12
  @max_timeout_ms 180_000
  @max_memory_entries 20
  @direct_model_origins [:cli, :api, :tui]
  @reserved_context ["jido_console", "coding"]

  @schema Zoi.struct(
            __MODULE__,
            %{
              source: Zoi.any(),
              base_spec: Zoi.any(),
              bound_spec: Zoi.any(),
              base_spec_digest: Zoi.any(),
              bound_spec_digest: Zoi.any(),
              pack: Zoi.any(),
              model_id: Zoi.any(),
              model_origin: Zoi.any(),
              execution_policy: Zoi.any(),
              workspace: Zoi.any(),
              workspace_configuration: Zoi.any(),
              workspace_configuration_digest: Zoi.any(),
              runtime_definition: Zoi.any(),
              runtime_definition_fingerprint: Zoi.any(),
              safe_context: Zoi.any()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type model_origin :: :agent_spec | :cli | :api | :tui
  @type t :: %__MODULE__{
          source: SourceRecord.t(),
          base_spec: Spec.t(),
          bound_spec: Spec.t(),
          base_spec_digest: String.t(),
          bound_spec_digest: String.t(),
          pack: Pack.t(),
          model_id: String.t(),
          model_origin: model_origin(),
          execution_policy: Selection.t(),
          workspace: map() | nil,
          workspace_configuration: map(),
          workspace_configuration_digest: String.t(),
          runtime_definition: term(),
          runtime_definition_fingerprint: String.t(),
          safe_context: map()
        }

  @doc "Builds one bound spec from independent immutable selections."
  @spec build(SourceRecord.t(), Pack.t() | term(), term(), Selection.t(), map() | nil, keyword()) ::
          {:ok, t()} | {:needs_model, map()} | {:error, term()}
  def build(source, pack, model_choice, execution_policy, workspace, opts \\ [])

  def build(
        %SourceRecord{} = source,
        pack_input,
        model_choice,
        %Selection{} = execution_policy,
        workspace,
        opts
      )
      when is_list(opts) do
    with {:ok, pack} <- normalize_pack(pack_input),
         :ok <- validate_source(source, opts),
         :ok <- validate_policy(execution_policy, source.base_spec),
         {:ok, workspace} <- validate_workspace(workspace, execution_policy.workspace),
         {:ok, model} <- ModelCommands.resolve_effective(source.base_spec.model, model_choice, opts),
         {:ok, bound_spec} <- bind_spec(source.base_spec, pack, model.id, execution_policy, opts),
         {:ok, bound_spec_digest} <- spec_digest(:agent_bound_spec, bound_spec),
         {:ok, workspace_configuration, workspace_configuration_digest} <- workspace_configuration(opts),
         runtime_definition =
           Keyword.get_lazy(opts, :runtime_definition, fn -> Pack.runtime_definition(pack, opts) end),
         {:ok, runtime_definition_fingerprint} <-
           ExtensionSetup.runtime_definition_fingerprint(runtime_definition) do
      binding = %__MODULE__{
        source: source,
        base_spec: source.base_spec,
        bound_spec: bound_spec,
        base_spec_digest: source.base_spec_digest,
        bound_spec_digest: bound_spec_digest,
        pack: pack,
        model_id: model.id,
        model_origin: model.origin,
        execution_policy: execution_policy,
        workspace: workspace,
        workspace_configuration: workspace_configuration,
        workspace_configuration_digest: workspace_configuration_digest,
        runtime_definition: runtime_definition,
        runtime_definition_fingerprint: runtime_definition_fingerprint,
        safe_context: %{}
      }

      {:ok, %{binding | safe_context: build_safe_context(binding)}}
    else
      {:needs_model, _state} = state -> state
      {:error, _reason} = error -> error
    end
  end

  def build(_source, _pack, _model_choice, _execution_policy, _workspace, _opts),
    do: {:error, :invalid_binding_inputs}

  @doc "Rebuilds from a new immutable base source and never retunes the old bound spec."
  @spec rebind_source(t(), SourceRecord.t(), keyword()) ::
          {:ok, t()} | {:needs_model, map()} | {:error, term()}
  def rebind_source(%__MODULE__{} = binding, %SourceRecord{} = source, opts \\ []) do
    model_choice =
      if binding.model_origin in @direct_model_origins,
        do: %{id: binding.model_id, origin: binding.model_origin},
        else: nil

    opts =
      opts
      |> Keyword.put_new(:workspace_configuration, binding.workspace_configuration)
      |> Keyword.put_new(:runtime_definition, binding.runtime_definition)

    build(
      source,
      binding.pack,
      model_choice,
      binding.execution_policy,
      binding.workspace,
      opts
    )
  end

  @doc "Returns the single allowlisted binding projection for views and model context."
  @spec safe_context(t()) :: map()
  def safe_context(%__MODULE__{safe_context: context}), do: context

  @doc "Merges caller context only when it does not use a host-owned namespace."
  @spec merge_context(t(), map()) :: {:ok, map()} | {:error, term()}
  def merge_context(%__MODULE__{} = binding, caller_context) when is_map(caller_context) do
    case reserved_collision(caller_context) do
      nil -> {:ok, Map.merge(caller_context, safe_context(binding))}
      namespace -> {:error, {:reserved_context_namespace, namespace}}
    end
  end

  def merge_context(%__MODULE__{}, _caller_context), do: {:error, :invalid_prompt_context}

  defp normalize_pack(%Pack{} = pack), do: {:ok, pack}
  defp normalize_pack(value), do: Pack.from_input(value)

  defp validate_source(%SourceRecord{} = source, opts) do
    if Keyword.get(opts, :verify_base_spec_digest?, true) do
      with true <- source.agent_id == source.base_spec.id,
           {:ok, digest} <- spec_digest(:agent_base_spec, source.base_spec),
           true <- digest == source.base_spec_digest do
        :ok
      else
        false -> {:error, :invalid_agent_source_record}
        {:error, _reason} = error -> error
      end
    else
      if source.agent_id == source.base_spec.id,
        do: :ok,
        else: {:error, :invalid_agent_source_record}
    end
  end

  defp validate_policy(%Selection{} = selection, %Spec{} = spec) do
    with :selected <- selection.state,
         true <- is_binary(selection.execution_policy_id),
         %Record{} = record <- selection.record,
         {:ok, ^record} <- Record.validate(record),
         true <- record.execution_policy_id == selection.execution_policy_id,
         true <- record.jidoka_selection == selection.jidoka_selection,
         true <- policy_request_matches?(spec.execution_profile, selection.execution_policy_id) do
      :ok
    else
      _invalid -> {:error, :invalid_execution_policy_selection}
    end
  end

  defp policy_request_matches?(nil, _selected), do: true

  defp policy_request_matches?(requested, selected) when is_binary(requested),
    do: ExecutionPolicy.normalize_id(requested) == selected

  defp policy_request_matches?(_requested, _selected), do: false

  defp validate_workspace(nil, nil), do: {:ok, nil}
  defp validate_workspace(workspace, nil) when is_map(workspace), do: {:ok, workspace}
  defp validate_workspace(nil, policy_workspace) when is_map(policy_workspace), do: {:ok, policy_workspace}

  defp validate_workspace(workspace, policy_workspace)
       when is_map(workspace) and is_map(policy_workspace) do
    if workspace_identity(workspace) == workspace_identity(policy_workspace) and
         workspace_digest(workspace) == workspace_digest(policy_workspace),
       do: {:ok, workspace},
       else: {:error, :workspace_identity_mismatch}
  end

  defp validate_workspace(_workspace, _policy_workspace), do: {:error, :invalid_workspace_identity}

  defp bind_spec(base_spec, pack, model_id, execution_policy, opts) do
    with {:ok, spec} <- Pack.apply(pack, base_spec),
         {:ok, spec} <- put_model(spec, model_id),
         {:ok, spec} <- put_policy(spec, execution_policy.execution_policy_id),
         {:ok, spec} <- apply_runtime_caps(spec, opts),
         {:ok, spec} <- apply_memory_caps(spec, opts) do
      put_pack_instructions(spec, pack)
    end
  end

  defp put_model(%Spec{} = spec, model_id) do
    Spec.new(spec |> Map.from_struct() |> Map.put(:model, model_id))
  end

  defp put_policy(%Spec{} = spec, execution_policy_id) do
    Spec.new(spec |> Map.from_struct() |> Map.put(:execution_profile, execution_policy_id))
  end

  defp apply_runtime_caps(%Spec{} = spec, opts) do
    max_turns = positive_cap(opts, :max_model_turns_cap, @max_model_turns)
    timeout_ms = positive_cap(opts, :timeout_ms_cap, @max_timeout_ms)

    with {:ok, defaults} <- clamp_default(spec.runtime_defaults, :max_model_turns, max_turns),
         {:ok, defaults} <- clamp_default(defaults, :timeout_ms, timeout_ms) do
      Spec.new(spec |> Map.from_struct() |> Map.put(:runtime_defaults, defaults))
    end
  end

  defp clamp_default(defaults, key, maximum) when is_map(defaults) do
    value = Map.get(defaults, key, Map.get(defaults, Atom.to_string(key)))

    cond do
      is_nil(value) ->
        {:ok, defaults}

      is_integer(value) and value > 0 ->
        {:ok,
         defaults
         |> Map.delete(Atom.to_string(key))
         |> Map.put(key, min(value, maximum))}

      true ->
        {:error, {:invalid_agent_runtime_default, key}}
    end
  end

  defp apply_memory_caps(%Spec{memory: nil} = spec, _opts), do: {:ok, spec}

  defp apply_memory_caps(%Spec{memory: %Memory{} = memory} = spec, opts) do
    maximum = positive_cap(opts, :memory_max_entries_cap, @max_memory_entries)

    attrs =
      memory
      |> Map.from_struct()
      |> Map.put(:scope, :session)
      |> Map.put(:namespace, nil)
      |> Map.put(:max_entries, min(memory.max_entries, maximum))

    with {:ok, memory} <- Memory.new(attrs) do
      Spec.new(spec |> Map.from_struct() |> Map.put(:memory, memory))
    end
  end

  defp apply_memory_caps(%Spec{}, _opts), do: {:error, :invalid_agent_memory}

  defp put_pack_instructions(%Spec{} = spec, %Pack{} = pack) do
    case Pack.instructions(pack) do
      "" ->
        {:ok, spec}

      instructions ->
        Spec.new(
          spec
          |> Map.from_struct()
          |> Map.put(:instructions, spec.instructions <> "\n\n" <> instructions)
        )
    end
  end

  defp workspace_configuration(opts) do
    configuration = Keyword.get(opts, :workspace_configuration, %{})

    with true <- is_map(configuration),
         {:ok, _portable_digest} <- ExtensionSetup.runtime_definition_fingerprint(configuration) do
      {:ok, configuration, Digest.semantic(:workspace_configuration, configuration)}
    else
      false -> {:error, :invalid_workspace_configuration}
      {:error, _reason} -> {:error, :invalid_workspace_configuration}
    end
  end

  defp spec_digest(subject, %Spec{} = spec) do
    projection = Jidoka.project(spec)

    case ExtensionSetup.runtime_definition_fingerprint(projection) do
      {:ok, _validation_digest} -> {:ok, Digest.semantic(subject, projection)}
      {:error, reason} -> {:error, {:nonportable_agent_spec, reason}}
    end
  rescue
    _exception -> {:error, :invalid_agent_spec_projection}
  end

  defp build_safe_context(%__MODULE__{} = binding) do
    %{
      "jido_console" => %{
        "agent" => %{
          "id" => binding.source.agent_id,
          "source" => %{
            "kind" => Atom.to_string(binding.source.kind),
            "digest" => binding.source.digest,
            "label" => binding.source.label
          }
        },
        "coding_pack" => Pack.projection(binding.pack),
        "model" => %{
          "id" => binding.model_id,
          "origin" => Atom.to_string(binding.model_origin)
        },
        "execution_policy" => %{"id" => binding.execution_policy.execution_policy_id},
        "workspace" => %{"identity_digest" => workspace_digest(binding.workspace)}
      }
    }
  end

  defp reserved_collision(context) do
    Enum.find_value(Map.keys(context), fn key ->
      normalized = if is_atom(key), do: Atom.to_string(key), else: key
      if normalized in @reserved_context, do: normalized
    end)
  end

  defp workspace_identity(workspace) when is_map(workspace) do
    {
      field(workspace, :major_device),
      field(workspace, :minor_device),
      field(workspace, :inode)
    }
  end

  defp workspace_digest(nil), do: nil
  defp workspace_digest(workspace), do: field(workspace, :digest)

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp positive_cap(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> min(value, default)
      _value -> default
    end
  end
end
