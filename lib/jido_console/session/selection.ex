defmodule Jido.Console.Session.Selection do
  @moduledoc "Pure owner state for draft, locked, and blocked session bindings."

  alias Jido.Console.AgentSource
  alias Jido.Console.AgentSource.Record, as: SourceRecord
  alias Jido.Console.Coding.Pack
  alias Jido.Console.Digest
  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.ExecutionPolicy.{Record, Selection}
  alias Jido.Console.Session.{Binding, BindingManifest, BindingRequest, Legacy}
  alias Jidoka.Session.Data

  @schema Zoi.struct(
            __MODULE__,
            %{
              state: Zoi.any(),
              binding: Zoi.any(),
              manifest: Zoi.any(),
              source: Zoi.any(),
              pack: Zoi.any(),
              model_choice: Zoi.any(),
              policy: Zoi.any(),
              generation: Zoi.any(),
              blocked_reason: Zoi.any(),
              options: Zoi.any()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type binding_state ::
          :needs_model | :needs_policy | :ready_unlocked | :locked | :resume_blocked
  @type t :: %__MODULE__{
          state: binding_state(),
          binding: Binding.t() | nil,
          manifest: map() | nil,
          source: SourceRecord.t() | nil,
          pack: Pack.t() | nil,
          model_choice: map() | nil,
          policy: Selection.t() | nil,
          generation: non_neg_integer(),
          blocked_reason: term() | nil,
          options: keyword()
        }

  @doc "Builds one new owner selection without opening runtime resources."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    with {:ok, source} <- source_from_options(opts),
         {:ok, pack} <- Pack.resolve(opts),
         {:ok, model_choice} <- model_choice(opts),
         {:ok, direct_choice} <- direct_policy_choice(opts) do
      resolve(source, pack, model_choice, direct_choice, opts, 0)
    end
  end

  def new(_opts), do: {:error, :invalid_session_selection_options}

  @doc "Rebuilds and validates the exact stored binding before recovery or resources."
  @spec resume(Data.t(), keyword()) :: {:ok, t()} | {:rebind, t()} | {:blocked, t()}
  def resume(%Data{} = session, opts \\ []) when is_list(opts) do
    legacy_events_present? = Keyword.get(opts, :legacy_events_present?, false)
    opts = Keyword.delete(opts, :legacy_events_present?)

    case BindingManifest.fetch(session) do
      {:ok, manifest} -> resume_manifest(session, manifest, opts)
      {:error, :binding_manifest_missing} -> legacy_resume(session, legacy_events_present?, opts)
      {:error, reason} -> {:blocked, blocked(reason, opts)}
    end
  end

  @doc "Returns the current binding state."
  @spec state(t()) :: binding_state()
  def state(%__MODULE__{state: state}), do: state

  @doc "Returns true after the first prompt binding is durably locked."
  @spec locked?(t()) :: boolean()
  def locked?(%__MODULE__{state: :locked}), do: true
  def locked?(%__MODULE__{}), do: false

  @doc "Returns one safe binding projection for Session View."
  @spec safe_projection(t()) :: map()
  def safe_projection(%__MODULE__{manifest: manifest}) when is_map(manifest) do
    BindingManifest.safe_projection(manifest)
  end

  def safe_projection(%__MODULE__{source: %SourceRecord{} = source} = selection) do
    %{
      "agent" => %{
        "id" => source.agent_id,
        "source" => %{
          "kind" => Atom.to_string(source.kind),
          "digest" => source.digest,
          "label" => source.label
        }
      },
      "coding_pack" => if(selection.pack, do: Pack.projection(selection.pack), else: nil),
      "model" => selection.model_choice,
      "execution_policy" => %{
        "id" => if(selection.policy, do: selection.policy.execution_policy_id, else: nil)
      },
      "workspace" => %{"identity_digest" => nil}
    }
  end

  def safe_projection(%__MODULE__{}), do: %{}

  @doc "Stores the ready draft in a new durable Jidoka session."
  @spec start_session(t(), String.t()) :: {:ok, Data.t()} | {:error, term()}
  def start_session(
        %__MODULE__{state: :ready_unlocked, binding: %Binding{} = binding, manifest: manifest},
        thread_id
      ) do
    with {:ok, session} <- Data.start(binding.bound_spec, session_id: thread_id),
         {:ok, session} <- BindingManifest.put(session, manifest) do
      {:ok, session}
    end
  end

  def start_session(%__MODULE__{}, _thread_id), do: {:error, :binding_not_ready}

  @doc "Builds the next revision for one changed unlocked draft."
  @spec put_draft(t(), Data.t()) :: {:ok, Data.t()} | {:error, term()}
  def put_draft(
        %__MODULE__{state: :ready_unlocked, binding: %Binding{} = binding, manifest: manifest},
        %Data{} = session
      ) do
    session = %{
      session
      | agent_id: binding.bound_spec.id,
        spec: binding.bound_spec,
        revision: session.revision + 1
    }

    BindingManifest.put(session, manifest)
  end

  def put_draft(%__MODULE__{}, %Data{}), do: {:error, :binding_not_ready}

  @doc "Locks the current manifest to one exact first-prompt operation."
  @spec lock(t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def lock(
        %__MODULE__{state: :ready_unlocked, binding: %Binding{} = binding} = selection,
        operation_id,
        command_digest
      ) do
    with {:ok, manifest} <-
           BindingManifest.new(binding,
             lock_state: :locked,
             draft_generation: selection.generation,
             lock_operation_id: operation_id,
             first_prompt_command_digest: command_digest
           ) do
      {:ok, %{selection | state: :locked, manifest: manifest}}
    end
  end

  def lock(%__MODULE__{}, _operation_id, _command_digest), do: {:error, :binding_not_ready}

  @doc "Rebuilds an unlocked selection with a direct model choice."
  @spec select_model(t(), String.t(), atom()) :: {:ok, t()} | {:error, term()}
  def select_model(%__MODULE__{state: state} = selection, identity, origin)
      when state in [:ready_unlocked, :needs_model, :needs_policy] and is_binary(identity) and
             origin in [:cli, :api, :tui] do
    direct = if(selection.policy, do: selection.policy.direct_choice)

    resolve_change(
      selection,
      selection.source,
      %{id: identity, origin: origin},
      direct,
      selection.options
    )
  end

  def select_model(%__MODULE__{state: :locked}, _identity, _origin), do: {:error, :binding_locked}
  def select_model(%__MODULE__{state: :resume_blocked}, _identity, _origin), do: {:error, :resume_blocked}
  def select_model(%__MODULE__{}, _identity, _origin), do: {:error, :binding_not_ready}

  @doc "Rebuilds an unlocked selection from another supported agent source."
  @spec select_agent(t(), term()) :: {:ok, t()} | {:error, term()}
  def select_agent(%__MODULE__{state: state} = selection, source_input)
      when state in [:ready_unlocked, :needs_model, :needs_policy] do
    with {:ok, source} <- source_record(source_input, selection.options) do
      direct = if(selection.policy, do: selection.policy.direct_choice)

      resolve_change(
        selection,
        source,
        retained_model_choice(selection),
        direct,
        selection.options
      )
    end
  end

  def select_agent(%__MODULE__{state: :locked}, _input), do: {:error, :binding_locked}
  def select_agent(%__MODULE__{state: :resume_blocked}, _input), do: {:error, :resume_blocked}

  @doc "Rebuilds an unlocked selection with direct execution-policy consent."
  @spec select_execution_policy(t(), String.t(), Path.t() | nil, atom()) ::
          {:ok, t()} | {:error, term()}
  def select_execution_policy(%__MODULE__{state: state} = selection, id, root, origin)
      when state in [:ready_unlocked, :needs_model, :needs_policy] and origin in [:cli, :api, :tui] do
    opts = if root, do: Keyword.put(selection.options, :project_root, root), else: selection.options

    with {:ok, direct} <- ExecutionPolicy.direct_choice(id, origin) do
      resolve_change(
        selection,
        selection.source,
        retained_model_choice(selection),
        direct,
        opts
      )
    end
  end

  def select_execution_policy(%__MODULE__{state: :locked}, _id, _root, _origin),
    do: {:error, :binding_locked}

  def select_execution_policy(%__MODULE__{state: :resume_blocked}, _id, _root, _origin),
    do: {:error, :resume_blocked}

  @doc "Checks explicit attach choices against the authoritative owner binding."
  @spec match_request(t(), BindingRequest.t()) :: :ok | {:error, term()}
  def match_request(%__MODULE__{} = selection, %BindingRequest{} = request) do
    with :ok <- match_agent(selection, request.agent_source),
         :ok <- match_pack(selection, request.coding_pack),
         :ok <- match_value(:model, selected_model(selection), request.model),
         :ok <- match_value(:execution_policy, selected_policy(selection), request.execution_policy),
         :ok <- match_root(selection, request.project_root) do
      :ok
    end
  end

  defp resolve(source, pack, model_choice, direct_choice, opts, generation) do
    policy_opts = [
      agent_request: source.base_spec.execution_profile,
      direct_choice: direct_choice,
      project_root: Keyword.get(opts, :project_root),
      thread_id: Keyword.get(opts, :thread_id)
    ]

    policy_opts = maybe_registry(policy_opts, opts)

    case ExecutionPolicy.resolve(policy_opts) do
      {:ok, policy} ->
        binding(source, pack, model_choice, policy, opts, generation)

      {:error, {:consent_required, _id}} ->
        {:ok, pending(:needs_policy, source, pack, model_choice, nil, generation, opts, nil)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp binding(source, pack, model_choice, policy, opts, generation) do
    build_opts =
      Keyword.put(
        opts,
        :workspace_configuration,
        workspace_configuration(opts)
      )

    case Binding.build(source, pack, model_choice, policy, policy.workspace, build_opts) do
      {:ok, binding} ->
        with {:ok, manifest} <- BindingManifest.new(binding, draft_generation: generation) do
          {:ok,
           %__MODULE__{
             state: :ready_unlocked,
             binding: binding,
             manifest: manifest,
             source: source,
             pack: pack,
             model_choice: %{id: binding.model_id, origin: binding.model_origin},
             policy: policy,
             generation: generation,
             blocked_reason: nil,
             options: opts
           }}
        end

      {:needs_model, details} ->
        {:ok, pending(:needs_model, source, pack, model_choice, policy, generation, opts, details)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_change(selection, source, model_choice, direct, opts) do
    case resolve(
           source,
           selection.pack,
           model_choice,
           direct,
           opts,
           selection.generation + 1
         ) do
      {:ok, %__MODULE__{state: state} = pending} when state in [:needs_model, :needs_policy] ->
        {:ok, %{pending | generation: selection.generation}}

      result ->
        result
    end
  end

  defp resume_manifest(session, manifest, opts) do
    with {:ok, source} <- stored_source(manifest, opts),
         {:ok, pack} <- stored_pack(manifest),
         {:ok, policy} <- stored_policy(manifest, source, opts),
         {:ok, model_choice} <- stored_model(manifest),
         {:ok, binding} <-
           Binding.build(
             source,
             pack,
             model_choice,
             policy,
             policy.workspace,
             Keyword.put(
               opts,
               :workspace_configuration,
               get_in(manifest, ["workspace", "configuration"]) || %{}
             )
           ),
         {:ok, rebuilt} <- rebuild_manifest(binding, manifest),
         true <- rebuilt == manifest,
         :ok <- validate_stored_session(session, binding, manifest) do
      state = if manifest["lock_state"] == "locked", do: :locked, else: :ready_unlocked

      {:ok,
       %__MODULE__{
         state: state,
         binding: binding,
         manifest: manifest,
         source: source,
         pack: pack,
         model_choice: model_choice,
         policy: policy,
         generation: manifest["draft_generation"],
         blocked_reason: nil,
         options: opts
       }}
    else
      false -> {:blocked, blocked(:binding_manifest_mismatch, opts)}
      {:needs_model, details} -> {:blocked, blocked({:stored_model_unavailable, details}, opts)}
      {:error, reason} -> {:blocked, blocked(reason, opts)}
    end
  end

  defp rebuild_manifest(binding, manifest) do
    BindingManifest.new(binding,
      lock_state: manifest["lock_state"],
      draft_generation: manifest["draft_generation"],
      lock_operation_id: manifest["lock_operation_id"],
      first_prompt_command_digest: manifest["first_prompt_command_digest"]
    )
  end

  defp validate_stored_session(session, binding, %{"lock_state" => "draft"}) do
    if session.agent_id == binding.bound_spec.id and session.spec == binding.bound_spec,
      do: :ok,
      else: {:error, :stored_bound_spec_mismatch}
  end

  defp validate_stored_session(session, binding, %{"lock_state" => "locked"}) do
    if session.agent_id == binding.bound_spec.id,
      do: :ok,
      else: {:error, :stored_agent_id_mismatch}
  end

  defp legacy_resume(session, legacy_events_present?, opts) do
    if not legacy_events_present? and session.revision == 0 and Legacy.unused?(session) do
      case new(opts) do
        {:ok, %__MODULE__{state: :ready_unlocked} = selection} -> {:rebind, selection}
        {:ok, _pending} -> {:blocked, blocked(:legacy_session_requires_complete_binding, opts)}
        {:error, reason} -> {:blocked, blocked(reason, opts)}
      end
    else
      {:blocked, blocked(:legacy_session_has_history, opts)}
    end
  end

  defp stored_source(manifest, opts) do
    identity = get_in(manifest, ["source", "identity"])

    source_input =
      case identity do
        "builtin:jido" -> "builtin:jido"
        %{"path" => path} -> path
        _other -> Keyword.get(opts, :agent, Jido.Console.Agents.Default)
      end

    with {:ok, source} <- source_record(source_input, opts),
         true <- source_evidence(source) == manifest["source"] do
      {:ok, source}
    else
      false -> {:error, :agent_source_evidence_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp stored_pack(%{"coding_pack" => %{"id" => nil, "status" => "disabled"}}),
    do: Pack.from_input(:disabled)

  defp stored_pack(%{"coding_pack" => %{"id" => id, "status" => "enabled"}}),
    do: Pack.from_input(id)

  defp stored_pack(_manifest), do: {:error, :invalid_stored_coding_pack}

  defp stored_policy(manifest, source, opts) do
    id = get_in(manifest, ["execution_policy", "id"])
    root = get_in(manifest, ["workspace", "identity", "root"])

    with {:ok, direct} <- ExecutionPolicy.direct_choice(id, :api),
         policy_opts =
           [agent_request: source.base_spec.execution_profile, direct_choice: direct, project_root: root]
           |> maybe_registry(opts),
         {:ok, policy} <- ExecutionPolicy.resolve(policy_opts),
         true <- policy_evidence(policy) == manifest["execution_policy"],
         true <- workspace_evidence(policy.workspace) == manifest["workspace"]["identity"] do
      {:ok, %{policy | origin: :stored, direct_choice: nil}}
    else
      false -> {:error, :execution_policy_evidence_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp stored_model(%{"model" => %{"id" => id, "origin" => origin}}) do
    case origin_atom(origin) do
      nil -> {:error, :invalid_stored_model_origin}
      atom -> {:ok, %{id: id, origin: atom}}
    end
  end

  defp source_from_options(opts) do
    input =
      cond do
        Keyword.has_key?(opts, :agent_source) -> Keyword.get(opts, :agent_source)
        Keyword.has_key?(opts, :agent) -> Keyword.get(opts, :agent)
        true -> "builtin:jido"
      end

    source_record(input, opts)
  end

  defp source_record(nil, opts), do: AgentSource.resolve(nil, opts)
  defp source_record(input, opts) when is_binary(input), do: AgentSource.resolve(input, opts)

  defp source_record(input, _opts) do
    with {:ok, spec} <- Jidoka.Agent.Spec.from_input(input) do
      projection = Jidoka.project(spec)
      bytes = Digest.semantic_bytes(:compiled_agent_source, projection)

      {:ok,
       SourceRecord.build(
         base_spec: spec,
         identity: "compiled:" <> spec.id,
         kind: :builtin,
         format: :compiled,
         byte_size: byte_size(bytes),
         digest: Digest.portable(bytes),
         base_spec_digest: Digest.semantic(:agent_base_spec, projection),
         agent_id: spec.id,
         label: spec.id
       )}
    else
      {:error, _reason} -> {:error, :invalid_agent_source}
    end
  end

  defp direct_policy_choice(opts) do
    if Keyword.has_key?(opts, :execution_policy) or Keyword.has_key?(opts, :coding_profile) do
      origin = Keyword.get(opts, :execution_policy_origin, :api)
      ExecutionPolicy.direct_choice(opts, origin)
    else
      {:ok, nil}
    end
  end

  defp model_choice(opts) do
    if Keyword.has_key?(opts, :model) do
      id = Keyword.get(opts, :model)
      origin = Keyword.get(opts, :model_origin, :api)

      if is_binary(id) and id != "" and origin in [:cli, :api, :tui],
        do: {:ok, %{id: id, origin: origin}},
        else: {:error, :invalid_model_choice}
    else
      {:ok, nil}
    end
  end

  defp workspace_configuration(opts) do
    %{
      "working_directory" => Keyword.get(opts, :coding_working_directory, "."),
      "access" => Keyword.get(opts, :coding_access),
      "limits" => Keyword.get(opts, :coding_limits)
    }
  end

  defp maybe_registry(policy_opts, opts) do
    case Keyword.fetch(opts, :execution_policy_registry) do
      {:ok, registry} -> Keyword.put(policy_opts, :registry, registry)
      :error -> policy_opts
    end
  end

  defp pending(state, source, pack, model_choice, policy, generation, opts, reason) do
    %__MODULE__{
      state: state,
      binding: nil,
      manifest: nil,
      source: source,
      pack: pack,
      model_choice: model_choice,
      policy: policy,
      generation: generation,
      blocked_reason: reason,
      options: opts
    }
  end

  defp blocked(reason, opts) do
    %__MODULE__{
      state: :resume_blocked,
      binding: nil,
      manifest: nil,
      source: nil,
      pack: nil,
      model_choice: nil,
      policy: nil,
      generation: 0,
      blocked_reason: reason,
      options: opts
    }
  end

  defp retained_model_choice(%__MODULE__{binding: %Binding{} = binding}) do
    if binding.model_origin in [:cli, :api, :tui],
      do: %{id: binding.model_id, origin: binding.model_origin},
      else: nil
  end

  defp retained_model_choice(%__MODULE__{model_choice: choice}), do: choice

  defp match_agent(_selection, nil), do: :ok

  defp match_agent(%__MODULE__{source: source, options: opts}, input) do
    case source_record(input, opts) do
      {:ok, requested} ->
        if source_evidence(requested) == source_evidence(source),
          do: :ok,
          else: conflict(:agent_source)

      {:error, _reason} ->
        conflict(:agent_source)
    end
  end

  defp match_pack(_selection, nil), do: :ok

  defp match_pack(%__MODULE__{pack: selected}, input) do
    case Pack.from_input(input) do
      {:ok, requested} ->
        if Pack.projection(requested) == Pack.projection(selected), do: :ok, else: conflict(:coding_pack)

      {:error, _reason} ->
        conflict(:coding_pack)
    end
  end

  defp match_value(_field, _selected, nil), do: :ok
  defp match_value(_field, value, value), do: :ok
  defp match_value(field, _selected, _requested), do: conflict(field)

  defp match_root(_selection, nil), do: :ok

  defp match_root(%__MODULE__{binding: %Binding{workspace: workspace}}, root) when is_map(workspace) do
    if Path.expand(root) == field(workspace, :root), do: :ok, else: conflict(:project_root)
  end

  defp match_root(_selection, _root), do: conflict(:project_root)

  defp conflict(field), do: {:error, {:binding_conflict, field}}
  defp selected_model(%__MODULE__{binding: %Binding{model_id: id}}), do: id
  defp selected_model(%__MODULE__{model_choice: %{id: id}}), do: id
  defp selected_model(%__MODULE__{}), do: nil
  defp selected_policy(%__MODULE__{policy: %Selection{execution_policy_id: id}}), do: id
  defp selected_policy(%__MODULE__{}), do: nil

  defp source_evidence(%SourceRecord{} = source) do
    %{
      "identity" => portable(source.identity),
      "kind" => Atom.to_string(source.kind),
      "format" => Atom.to_string(source.format),
      "byte_size" => source.byte_size,
      "digest" => source.digest,
      "base_spec_digest" => source.base_spec_digest,
      "agent_id" => source.agent_id,
      "label" => source.label
    }
  end

  defp policy_evidence(%Selection{record: %Record{} = record}) do
    %{
      "id" => record.execution_policy_id,
      "profile_digest" => record.security_profile.digest,
      "profile_revision" => record.security_profile.revision,
      "registration_fingerprint" => record.registration_fingerprint
    }
  end

  defp workspace_evidence(nil), do: nil
  defp workspace_evidence(workspace), do: portable(workspace)

  defp portable(value) when is_atom(value), do: Atom.to_string(value)

  defp portable(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {portable(key), portable(item)} end)
  end

  defp portable(value) when is_list(value), do: Enum.map(value, &portable/1)
  defp portable(value), do: value

  defp origin_atom("agent_spec"), do: :agent_spec
  defp origin_atom("cli"), do: :cli
  defp origin_atom("api"), do: :api
  defp origin_atom("tui"), do: :tui
  defp origin_atom(_origin), do: nil

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
