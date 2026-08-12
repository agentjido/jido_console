defmodule Jido.Cli.Automation.Result do
  @moduledoc "Builds the stable JSONL result contract for one run cell."

  alias Jido.Cli.Automation.{Contract, Replay}
  alias Jidoka.ExecutionEnvironment
  alias Jidoka.ExecutionEnvironment.Binding
  alias Jidoka.ExecutionEnvironment.Checkpoint
  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.Registration
  alias Jidoka.Session.Environment

  @schema "jido.case-result"
  @schema_version 1
  @limit_fact_keys ~w(
    cpu cpu_count cpu_millis disk_mb duration_ms memory_mb output_bytes pids processes
    timeout_ms wall_ms
  )
  @checkpoint_fact_keys ~w(
    files forkable immutable kind network preservation preserves processes services supported tcp workspace
  )

  @doc "Builds one result record."
  @spec new(map(), keyword()) :: map()
  def new(cell, attrs) do
    Contract.case_result!(%{
      schema: @schema,
      schema_version: @schema_version,
      type: "case.result",
      run_id: cell.run_id,
      cell_id: cell.cell_id,
      sequence: cell.sequence,
      dimensions: cell.dimensions,
      sources: cell.sources,
      execution: Keyword.fetch!(attrs, :execution),
      execution_environment:
        execution_environment(
          cell,
          Keyword.get(attrs, :environment),
          Keyword.get(attrs, :environment_error)
        ),
      capability_replay: Keyword.get(attrs, :capability_replay, replay_projection(cell)),
      evaluation: Keyword.fetch!(attrs, :evaluation),
      turns: Keyword.get(attrs, :turns, []),
      usage: Keyword.get(attrs, :usage, %{}),
      error: Keyword.get(attrs, :error),
      extensions: result_extensions(cell, Keyword.get(attrs, :extensions, %{}))
    })
  end

  defp result_extensions(cell, values) do
    trust = get_in(cell, [:extensions, :projection]) || %{"status" => "not_requested"}
    Map.put(values, "jido.cli.trust", trust)
  end

  defp replay_projection(cell) do
    cell
    |> Map.get(:capability_replay, %{mode: :live})
    |> Replay.projection()
  end

  @doc "Projects requested, resolved, and confirmed environment facts."
  @spec execution_environment(map(), Environment.t() | nil | term(), term()) :: map()
  def execution_environment(cell, environment \\ nil, error \\ nil)

  def execution_environment(cell, _environment, _error)
      when not is_map_key(cell, :execution_environment),
      do: %{status: :not_requested}

  def execution_environment(%{execution_environment: nil}, _environment, _error),
    do: %{status: :not_requested}

  def execution_environment(%{execution_environment: resolved}, %Environment{} = environment, error) do
    resolved
    |> identity_projection()
    |> Map.put(:status, final_environment_status(environment, error))
    |> Map.put(:binding, binding_projection(environment.binding))
    |> Map.put(:confirmed, evidence_projection(environment.evidence))
    |> Map.put(:lifecycle, lifecycle_projection(environment, error))
  end

  def execution_environment(
        %{execution_environment: resolved, capability_replay: %{mode: :replay}},
        _environment,
        _error
      ) do
    resolved
    |> identity_projection()
    |> Map.put(:status, :recorded)
  end

  def execution_environment(%{execution_environment: resolved}, _environment, error) do
    resolved
    |> identity_projection()
    |> Map.put(:status, failed_environment_status(error))
  end

  @doc "Returns a portable error map."
  @spec error(term()) :: map()
  def error(reason) do
    reason
    |> Jidoka.normalize_error(operation: :automation)
    |> Jidoka.error_to_map()
    |> portable_term()
  rescue
    exception -> %{category: "internal", message: Exception.message(exception)}
  end

  @doc "Aggregates numeric usage fields across turns."
  @spec usage([map()]) :: map()
  def usage(turns) do
    turns
    |> Enum.map(&Map.get(&1, :usage, %{}))
    |> Enum.reduce(%{}, fn usage, acc ->
      Enum.reduce(usage, acc, fn
        {key, value}, acc when is_number(value) -> Map.update(acc, key, value, &(&1 + value))
        _entry, acc -> acc
      end)
    end)
  end

  @doc "Computes the cell evaluation state from turn records."
  @spec evaluation([map()], atom()) :: map()
  def evaluation(_turns, execution_status) when execution_status != :ok do
    %{status: :not_run, assertion_count: 0, failed_assertion_count: 0}
  end

  def evaluation(turns, :ok) do
    assertions = Enum.flat_map(turns, &get_in(&1, [:evaluation, :assertions]))
    failed = Enum.count(assertions, &(Map.get(&1, :status) == :failed))

    status =
      cond do
        assertions == [] -> :unscored
        failed > 0 -> :failed
        true -> :passed
      end

    %{
      status: status,
      assertion_count: length(assertions),
      failed_assertion_count: failed
    }
  end

  defp portable_term(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp portable_term(value) when is_atom(value), do: Atom.to_string(value)
  defp portable_term(value) when is_tuple(value), do: value |> Tuple.to_list() |> portable_term()
  defp portable_term(value) when is_list(value), do: Enum.map(value, &portable_term/1)

  defp portable_term(%{__struct__: _struct} = value) do
    value
    |> Map.from_struct()
    |> portable_term()
  end

  defp portable_term(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {portable_key(key), portable_term(item)} end)
  end

  defp portable_term(value), do: inspect(value)

  defp portable_key(key) when is_binary(key) or is_atom(key), do: key
  defp portable_key(key), do: inspect(key)

  defp identity_projection(%{request: %PolicyRequest{} = request, registration: %Registration{} = registration}) do
    profile = registration.profile

    %{
      requested: %{
        profile_id: request.profile_id,
        capability_ids: request.capability_ids,
        policy_digest: ExecutionEnvironment.digest(PolicyRequest.to_map(request))
      },
      resolved: %{
        profile_id: profile.profile_id,
        profile_digest: profile.digest,
        registration_fingerprint: registration.fingerprint
      }
    }
  end

  defp identity_projection(_invalid), do: %{status: :rejected}

  defp binding_projection(%Binding{} = binding) do
    %{
      fingerprint: binding |> Binding.to_map() |> ExecutionEnvironment.digest(),
      revision: binding.revision,
      state: binding.state
    }
  end

  defp evidence_projection(%EnforcementEvidence{} = evidence) do
    %{
      status: evidence.status,
      adapter_id: evidence.adapter_id,
      backend: evidence.backend,
      isolation: evidence.isolation,
      network: evidence.network,
      workspace: evidence.workspace,
      image_digest: evidence.image_digest,
      applied_limits: select_evidence_facts(evidence.applied_limits, @limit_fact_keys),
      checkpoint: select_evidence_facts(evidence.checkpoint, @checkpoint_fact_keys),
      observed_at_ms: evidence.observed_at_ms,
      attestation_ref: evidence.attestation_ref
    }
  end

  defp lifecycle_projection(%Environment{} = environment, error) do
    failed_operation = lifecycle_operation(error)

    %{
      session_status: environment.status,
      checkpoint: lifecycle_observation(:checkpoint, failed_operation, not is_nil(environment.checkpoint)),
      restore: observation(environment.status == :restored, :unknown),
      fork: observation(environment.status == :forked, :unknown),
      close: lifecycle_observation(:close, failed_operation, true),
      cleanup:
        lifecycle_observation(
          :cleanup,
          failed_operation,
          environment.status == :cleaned,
          :not_applied
        ),
      checkpoint_facts: checkpoint_projection(environment.checkpoint)
    }
  end

  defp checkpoint_projection(nil), do: nil

  defp checkpoint_projection(%Checkpoint{} = checkpoint) do
    %{
      fingerprint: checkpoint |> Checkpoint.to_map() |> ExecutionEnvironment.digest(),
      binding_revision: checkpoint.binding_revision,
      evidence_digest: checkpoint.evidence_digest,
      preserves: select_evidence_facts(checkpoint.preserves, @checkpoint_fact_keys),
      forkable: checkpoint.forkable,
      created_at_ms: checkpoint.created_at_ms
    }
  end

  defp observation(true, _other), do: :confirmed
  defp observation(false, other), do: other

  defp lifecycle_observation(operation, operation, _observed, _other), do: :failed

  defp lifecycle_observation(_operation, _failed_operation, observed, other),
    do: observation(observed, other)

  defp lifecycle_observation(operation, failed_operation, observed),
    do: lifecycle_observation(operation, failed_operation, observed, :not_observed)

  defp final_environment_status(%Environment{} = environment, error) do
    case lifecycle_operation(error) do
      :cleanup -> :cleanup_failed
      :close -> :close_failed
      _operation -> final_environment_status_without_lifecycle_error(environment)
    end
  end

  defp final_environment_status_without_lifecycle_error(%Environment{status: :cleaned}), do: :closed

  defp final_environment_status_without_lifecycle_error(%Environment{evidence: %{status: :confirmed}}),
    do: :enforced

  defp final_environment_status_without_lifecycle_error(%Environment{}), do: :rejected

  defp failed_environment_status(error) do
    case lifecycle_operation(error) do
      :cleanup -> :cleanup_failed
      :close -> :close_failed
      :open -> if(policy_failure?(error), do: :rejected, else: :open_failed)
      _operation -> if(policy_failure?(error), do: :rejected, else: :open_failed)
    end
  end

  defp lifecycle_operation(%Jidoka.ExecutionEnvironment.Error{details: details}) do
    Map.get(details, :operation, Map.get(details, "operation"))
  end

  defp lifecycle_operation(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.find_value(&lifecycle_operation/1)
  end

  defp lifecycle_operation(value) when is_list(value), do: Enum.find_value(value, &lifecycle_operation/1)
  defp lifecycle_operation(_value), do: nil

  defp policy_failure?(:missing_execution_environment_policy), do: true
  defp policy_failure?({:invalid_execution_environment_policy, _policy}), do: true

  defp policy_failure?(%Jidoka.ExecutionEnvironment.Error{details: details}) do
    details
    |> Map.get(:reason, Map.get(details, "reason", ""))
    |> to_string()
    |> String.contains?("policy_denied")
  end

  defp policy_failure?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&policy_failure?/1)

  defp policy_failure?(value) when is_list(value), do: Enum.any?(value, &policy_failure?/1)
  defp policy_failure?(_value), do: false

  defp select_evidence_facts(map, allowed_keys) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, facts ->
      normalized_key = to_string(key)

      if normalized_key in allowed_keys do
        Map.put(facts, normalized_key, select_evidence_value(value, allowed_keys))
      else
        facts
      end
    end)
  end

  defp select_evidence_value(value, allowed_keys) when is_map(value),
    do: select_evidence_facts(value, allowed_keys)

  defp select_evidence_value(value, allowed_keys) when is_list(value),
    do: Enum.map(value, &select_evidence_value(&1, allowed_keys))

  defp select_evidence_value(value, _allowed_keys)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp select_evidence_value(_value, _allowed_keys), do: nil
end
