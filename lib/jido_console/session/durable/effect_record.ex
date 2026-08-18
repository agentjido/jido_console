defmodule Jido.Console.Session.Durable.EffectRecord do
  @moduledoc "Strict durable effect reservation and resolution payload validation."

  @kinds ~w(llm operation)
  @safety_classes ~w(safe deduplicated reconciled unsafe_once)
  @replay_rules ~w(replay dedupe reconcile never)
  @statuses ~w(intent_recorded started completed failed cancelled uncertain reconciled abandoned)

  @doc "Validates one immutable pre-dispatch reservation."
  @spec validate_reservation(map()) :: :ok | {:error, term()}
  def validate_reservation(payload) when is_map(payload) do
    cond do
      payload["effect_kind"] not in @kinds ->
        {:error, :invalid_effect_kind}

      payload["safety_class"] not in @safety_classes ->
        {:error, :invalid_effect_safety_class}

      payload["replay_rule"] not in @replay_rules ->
        {:error, :invalid_effect_replay_rule}

      not policy_pair?(payload["safety_class"], payload["replay_rule"]) ->
        {:error, :invalid_effect_policy_pair}

      payload["generation"] < 1 ->
        {:error, :invalid_effect_generation}

      not nullable_id?(payload["approval_id"]) ->
        {:error, :invalid_effect_approval_id}

      not nullable_id?(payload["credential_reference_id"]) ->
        {:error, :invalid_effect_credential_reference}

      not nullable_id?(payload["prior_attempt_id"]) ->
        {:error, :invalid_effect_prior_attempt}

      true ->
        :ok
    end
  end

  def validate_reservation(_payload), do: {:error, :invalid_effect_reservation}

  @doc "Validates one durable effect state transition."
  @spec validate_resolution(map()) :: :ok | {:error, term()}
  def validate_resolution(payload) when is_map(payload) do
    cond do
      payload["status"] not in @statuses ->
        {:error, :invalid_effect_status}

      payload["jidoka_revision"] < 0 ->
        {:error, :invalid_effect_jidoka_revision}

      payload["status"] == "completed" and is_nil(payload["result_digest"]) ->
        {:error, :completed_effect_result_digest_required}

      payload["status"] == "uncertain" and is_nil(payload["uncertainty_reason"]) ->
        {:error, :uncertain_effect_reason_required}

      not nullable_id?(payload["decision_id"]) ->
        {:error, :invalid_effect_decision_id}

      not nullable_id?(payload["uncertainty_reason"]) ->
        {:error, :invalid_effect_uncertainty_reason}

      true ->
        :ok
    end
  end

  def validate_resolution(_payload), do: {:error, :invalid_effect_resolution}

  @doc "Returns the closed replay policy table."
  @spec policy(atom()) :: {:ok, map()} | {:error, term()}
  def policy(idempotency) do
    case idempotency do
      value when value in [:pure, :idempotent] ->
        {:ok, %{safety_class: "safe", replay_rule: "replay", incomplete: :dispatch}}

      :dedupe ->
        {:ok, %{safety_class: "deduplicated", replay_rule: "dedupe", incomplete: :reconcile}}

      :reconcile ->
        {:ok, %{safety_class: "reconciled", replay_rule: "reconcile", incomplete: :reconcile}}

      :unsafe_once ->
        {:ok, %{safety_class: "unsafe_once", replay_rule: "never", incomplete: :uncertain}}

      other ->
        {:error, {:unsupported_effect_idempotency, other}}
    end
  end

  defp policy_pair?("safe", "replay"), do: true
  defp policy_pair?("deduplicated", "dedupe"), do: true
  defp policy_pair?("reconciled", "reconcile"), do: true
  defp policy_pair?("unsafe_once", "never"), do: true
  defp policy_pair?(_safety, _rule), do: false

  defp nullable_id?(nil), do: true
  defp nullable_id?(value), do: is_binary(value) and value != "" and byte_size(value) <= 256
end
