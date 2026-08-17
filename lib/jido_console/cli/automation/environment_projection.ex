defmodule Jido.Console.Automation.EnvironmentProjection do
  @moduledoc "Projects execution-environment facts into stable result values."

  alias Jidoka.ExecutionEnvironment
  alias Jidoka.ExecutionEnvironment.Binding
  alias Jidoka.ExecutionEnvironment.Checkpoint
  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.Selection
  alias Jidoka.Session.Environment

  @limit_fact_keys ~w(
    cpu cpu_count cpu_millis disk_mb duration_ms memory_mb output_bytes pids processes
    timeout_ms wall_ms
  )
  @checkpoint_fact_keys ~w(
    files forkable immutable kind network preservation preserves processes services supported tcp workspace
  )

  @doc "Projects requested, resolved, and confirmed environment facts."
  @spec project(map(), Environment.t() | nil | term(), term()) :: map()
  def project(cell, environment \\ nil, error \\ nil)

  def project(cell, _environment, _error) when not is_map_key(cell, :execution_environment),
    do: %{status: :not_requested}

  def project(%{execution_environment: nil}, _environment, _error),
    do: %{status: :not_requested}

  def project(%{execution_environment: resolved}, %Environment{} = environment, error) do
    resolved
    |> identity_projection()
    |> Map.put(:status, final_environment_status(environment, error))
    |> Map.put(:binding, binding_projection(environment.binding))
    |> Map.put(:confirmed, evidence_projection(environment.evidence))
    |> Map.put(:lifecycle, lifecycle_projection(environment, error))
  end

  def project(
        %{execution_environment: resolved, capability_replay: %{mode: :replay}},
        _environment,
        _error
      ) do
    resolved
    |> identity_projection()
    |> Map.put(:status, :recorded)
  end

  def project(%{execution_environment: resolved}, _environment, error) do
    resolved
    |> identity_projection()
    |> Map.put(:status, failed_environment_status(error))
  end

  defp identity_projection(%{selection: selection}) do
    case Selection.validate(selection) do
      {:ok, selection} ->
        request = Selection.request(selection)
        registration = Selection.registration(selection)
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

      {:error, _reason} ->
        %{status: :rejected}
    end
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
