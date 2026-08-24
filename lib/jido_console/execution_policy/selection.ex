defmodule Jido.Console.ExecutionPolicy.Selection do
  @moduledoc "Pure execution-policy decision matrix and workspace-evidence selector."

  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.ExecutionPolicy.{Consent, Record, Registry}
  alias Jidoka.ExecutionEnvironment

  @schema Zoi.struct(
            __MODULE__,
            %{
              state: Zoi.any(),
              execution_policy_id: Zoi.any(),
              record: Zoi.any(),
              jidoka_selection: Zoi.any(),
              origin: Zoi.any(),
              direct_choice: Zoi.any() |> Zoi.default(nil),
              workspace: Zoi.any() |> Zoi.default(nil),
              evidence: Zoi.any(),
              warning: Zoi.any() |> Zoi.default(nil)
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type t :: %__MODULE__{
          state: :selected,
          execution_policy_id: String.t(),
          record: Record.t(),
          jidoka_selection: Jidoka.ExecutionEnvironment.Selection.t(),
          origin: :default | :application | :agent_request | :cli | :api | :tui | :stored,
          direct_choice: Consent.t() | nil,
          workspace: map() | nil,
          evidence: map(),
          warning: String.t() | nil
        }

  @doc "Applies the R9 and R10 matrix without opening execution resources."
  @spec resolve(keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(opts \\ [])

  def resolve(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, registry} <- registry(opts),
         {:ok, agent_id} <- agent_request(opts),
         {:ok, proposal_id} <- application_proposal(opts),
         {:ok, direct} <- direct_choice(opts),
         {:ok, _agent_record} <- known_optional(registry, agent_id),
         {:ok, _proposal_record} <- known_optional(registry, proposal_id),
         {:ok, _direct_record} <- known_optional(registry, consent_id(direct)),
         :ok <- explicit_match(agent_id, direct) do
      choose(registry, agent_id, proposal_id, direct, opts)
    else
      false -> {:error, :invalid_execution_policy_options}
      {:error, _reason} = error -> error
    end
  end

  def resolve(_opts), do: {:error, :invalid_execution_policy_options}

  defp registry(opts) do
    case Keyword.get(opts, :registry) do
      nil ->
        :jido_console
        |> Application.get_env(:execution_policy_registry, Registry)
        |> registry_module()

      %Registry{} = registry ->
        {:ok, registry}

      module when is_atom(module) ->
        registry_module(module)

      _value ->
        {:error, :invalid_execution_policy_registry}
    end
  end

  defp registry_module(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :new, 1),
      do: module.new([]),
      else: {:error, :invalid_execution_policy_registry}
  end

  @doc false
  @spec validate_for_storage(t()) :: {:ok, t()} | {:error, term()}
  def validate_for_storage(
        %__MODULE__{
          state: :selected,
          execution_policy_id: id,
          record: %Record{} = record,
          jidoka_selection: jidoka_selection,
          origin: origin,
          direct_choice: %Consent{} = direct,
          workspace: workspace,
          evidence: evidence
        } = selection
      ) do
    with true <- ExecutionPolicy.valid_direct_consent?(direct),
         true <- direct.execution_policy_id == id,
         true <- direct.origin == origin,
         true <- record.execution_policy_id == id,
         {:ok, ^record} <- Record.validate(record),
         true <- record.jidoka_selection == jidoka_selection,
         {:ok, current_workspace} <- validate_workspace_evidence(record, workspace),
         true <- selection_evidence(record, current_workspace) == evidence do
      {:ok, selection}
    else
      _invalid -> {:error, :invalid_execution_policy_selection}
    end
  end

  def validate_for_storage(_selection), do: {:error, :invalid_execution_policy_selection}

  defp agent_request(opts) do
    case Keyword.get(opts, :agent_request) do
      nil ->
        {:ok, nil}

      id when is_binary(id) ->
        case ExecutionPolicy.policy_request(id) do
          {:ok, request} -> {:ok, request.profile_id}
          {:error, _reason} -> {:error, :invalid_agent_execution_policy_request}
        end

      _value ->
        {:error, :invalid_agent_execution_policy_request}
    end
  end

  defp application_proposal(opts) do
    if Keyword.has_key?(opts, :application_proposal) do
      normalize_optional(Keyword.get(opts, :application_proposal))
    else
      ExecutionPolicy.application_proposal()
    end
  end

  defp normalize_optional(nil), do: {:ok, nil}

  defp normalize_optional(id) when is_binary(id) do
    case ExecutionPolicy.normalize_id(id) do
      "" -> {:error, {:invalid_execution_policy_input, id}}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_optional(value), do: {:error, {:invalid_execution_policy_input, value}}

  defp direct_choice(opts) do
    case Keyword.get(opts, :direct_choice) do
      nil ->
        {:ok, nil}

      %Consent{} = consent ->
        if ExecutionPolicy.valid_direct_consent?(consent), do: {:ok, consent}, else: invalid_consent()

      _value ->
        invalid_consent()
    end
  end

  defp invalid_consent, do: {:error, :invalid_execution_policy_consent}

  defp known_optional(_registry, nil), do: {:ok, nil}
  defp known_optional(registry, id), do: Registry.fetch(registry, id)

  defp explicit_match(nil, _direct), do: :ok
  defp explicit_match(_agent_id, nil), do: :ok

  defp explicit_match(agent_id, %Consent{execution_policy_id: direct_id}) do
    if agent_id == direct_id,
      do: :ok,
      else: {:error, {:execution_policy_mismatch, agent_id, direct_id}}
  end

  defp choose(registry, agent_id, proposal_id, direct, opts) do
    {id, origin} = effective(agent_id, proposal_id, direct)

    with {:ok, record} <- Registry.fetch(registry, id) do
      cond do
        record.class == :restricted ->
          selected(record, origin, direct, opts)

        direct != nil ->
          selected(record, direct.origin, direct, opts)

        true ->
          select_with_stored_consent(record, opts)
      end
    end
  end

  defp effective(agent_id, _proposal_id, _direct) when is_binary(agent_id),
    do: {agent_id, :agent_request}

  defp effective(nil, _proposal_id, %Consent{execution_policy_id: id, origin: origin}),
    do: {id, origin}

  defp effective(nil, proposal_id, nil) when is_binary(proposal_id),
    do: {proposal_id, :application}

  defp effective(nil, nil, nil), do: {ExecutionPolicy.restricted_id(), :default}

  defp select_with_stored_consent(record, opts) do
    stored = Keyword.get(opts, :stored_consent)
    thread_id = Keyword.get(opts, :thread_id)

    if ExecutionPolicy.valid_stored_consent?(stored) and
         stored.execution_policy_id == record.execution_policy_id and
         stored.thread_id == thread_id do
      case selected(record, :stored, nil, opts) do
        {:ok, selection} = success ->
          if stored.evidence_digest == selection.evidence["evidence_digest"],
            do: success,
            else: consent_required(record)

        {:error, _reason} = error ->
          error
      end
    else
      consent_required(record)
    end
  end

  defp consent_required(record), do: {:error, {:consent_required, record.execution_policy_id}}

  defp selected(record, origin, direct, opts) do
    with {:ok, workspace} <- workspace(record, opts) do
      evidence = selection_evidence(record, workspace)

      {:ok,
       %__MODULE__{
         state: :selected,
         execution_policy_id: record.execution_policy_id,
         record: record,
         jidoka_selection: record.jidoka_selection,
         origin: origin,
         direct_choice: direct,
         workspace: workspace,
         evidence: evidence,
         warning: record.warning
       }}
    end
  end

  defp workspace(%Record{requires_workspace_root?: false}, opts) do
    case root_input(opts) do
      nil -> {:ok, nil}
      root -> optional_workspace(root)
    end
  end

  defp workspace(%Record{execution_policy_id: id, requires_workspace_root?: true}, opts) do
    case root_input(opts) do
      nil ->
        {:error, {:execution_policy_root_required, id}}

      root ->
        with {:ok, identity} <- root_identity(root, id),
             :ok <- root_matches(identity, expected_root(opts), id) do
          {:ok, identity}
        end
    end
  end

  defp optional_workspace(root) do
    expanded = Path.expand(root)

    case File.stat(expanded) do
      {:ok, %File.Stat{type: :directory} = stat} -> {:ok, identity(expanded, stat)}
      _result -> {:ok, nil}
    end
  end

  defp root_input(opts) do
    Keyword.get(opts, :project_root) ||
      Keyword.get(opts, :workspace_root) ||
      workspace_struct_root(Keyword.get(opts, :workspace))
  end

  defp expected_root(opts) do
    project_root = Keyword.get(opts, :project_root)
    workspace_root = Keyword.get(opts, :workspace_root) || workspace_struct_root(Keyword.get(opts, :workspace))

    if project_root && workspace_root, do: workspace_root, else: nil
  end

  defp workspace_struct_root(%{root: root}) when is_binary(root), do: root
  defp workspace_struct_root(_workspace), do: nil

  defp root_identity(root, id) when is_binary(root) and root != "" do
    expanded = Path.expand(root)

    case File.stat(expanded) do
      {:ok, %File.Stat{type: :directory} = stat} -> {:ok, identity(expanded, stat)}
      _result -> {:error, {:invalid_execution_policy_root, id}}
    end
  end

  defp root_identity(_root, id), do: {:error, {:invalid_execution_policy_root, id}}

  defp root_matches(_identity, nil, _id), do: :ok

  defp root_matches(identity, expected, id) do
    case root_identity(expected, id) do
      {:ok, expected_identity} ->
        if same_file?(identity, expected_identity),
          do: :ok,
          else: {:error, {:execution_policy_root_mismatch, id}}

      {:error, _reason} ->
        {:error, {:execution_policy_root_mismatch, id}}
    end
  end

  @doc false
  @spec same_workspace_identity?(map(), map()) :: boolean()
  def same_workspace_identity?(
        %{major_device: major, minor_device: minor, inode: inode},
        %{major_device: major, minor_device: minor, inode: inode}
      ),
      do: true

  def same_workspace_identity?(_left, _right), do: false

  defp same_file?(left, right), do: same_workspace_identity?(left, right)

  defp identity(root, stat) do
    subject = %{
      contract: "jido_console.execution_policy.workspace_identity.v1",
      root: root,
      major_device: stat.major_device,
      minor_device: stat.minor_device,
      inode: stat.inode
    }

    %{
      root: root,
      major_device: stat.major_device,
      minor_device: stat.minor_device,
      inode: stat.inode,
      digest: ExecutionEnvironment.digest(subject)
    }
  end

  defp selection_evidence(record, workspace) do
    base = Record.evidence(record)
    workspace_digest = if workspace, do: workspace.digest, else: nil

    subject = %{
      "contract" => "jido_console.execution_policy.selection_evidence.v1",
      "policy_evidence_digest" => base["evidence_digest"],
      "workspace_identity_digest" => workspace_digest
    }

    base
    |> Map.put("workspace_identity_digest", workspace_digest)
    |> Map.put("evidence_digest", ExecutionEnvironment.digest(subject))
  end

  defp consent_id(nil), do: nil
  defp consent_id(%Consent{execution_policy_id: id}), do: id

  defp validate_workspace_evidence(%Record{requires_workspace_root?: true} = record, workspace),
    do: current_workspace(record, workspace)

  defp validate_workspace_evidence(%Record{requires_workspace_root?: false}, nil), do: {:ok, nil}

  defp validate_workspace_evidence(%Record{} = record, workspace),
    do: current_workspace(record, workspace)

  defp current_workspace(%Record{execution_policy_id: id}, %{root: root} = stored) do
    with {:ok, current} <- root_identity(root, id),
         true <- same_workspace_identity?(stored, current),
         true <- Map.get(stored, :digest) == current.digest do
      {:ok, current}
    else
      _invalid -> {:error, :invalid_execution_policy_selection}
    end
  end

  defp current_workspace(_record, _workspace),
    do: {:error, :invalid_execution_policy_selection}
end
