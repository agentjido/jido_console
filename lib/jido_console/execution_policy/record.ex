defmodule Jido.Console.ExecutionPolicy.Record do
  @moduledoc "Trusted immutable host registration for one Console execution policy."

  alias Jidoka.ExecutionEnvironment.{
    AdapterCapabilities,
    PolicyRequest,
    Registration,
    SecurityProfile,
    Selection
  }

  alias Jidoka.ExecutionEnvironment

  @enforce_keys [
    :execution_policy_id,
    :class,
    :requires_workspace_root?,
    :policy_request,
    :security_profile,
    :adapter_capabilities,
    :registration,
    :jidoka_selection,
    :registration_fingerprint,
    :evidence
  ]

  defstruct [
    :execution_policy_id,
    :class,
    :warning,
    :requires_workspace_root?,
    :policy_request,
    :security_profile,
    :adapter_capabilities,
    :registration,
    :jidoka_selection,
    :registration_fingerprint,
    :evidence,
    manager_module: Jidoka.ExecutionEnvironment.Manager
  ]

  @type t :: %__MODULE__{
          execution_policy_id: String.t(),
          class: :restricted | :trusted_workspace,
          warning: String.t() | nil,
          requires_workspace_root?: boolean(),
          policy_request: PolicyRequest.t(),
          security_profile: SecurityProfile.t(),
          adapter_capabilities: AdapterCapabilities.t(),
          registration: Registration.t(),
          jidoka_selection: Selection.t(),
          registration_fingerprint: String.t(),
          evidence: map(),
          manager_module: module()
        }

  @doc "Validates the full immutable Jidoka selection held by this record."
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = record) do
    with true <- record.execution_policy_id == record.policy_request.profile_id,
         true <- record.execution_policy_id == record.security_profile.profile_id,
         true <- record.registration.profile == record.security_profile,
         true <- record.registration.capabilities == record.adapter_capabilities,
         true <- record.registration.fingerprint == record.registration_fingerprint,
         {:ok, selection} <- Selection.validate(record.jidoka_selection),
         true <- selection == record.jidoka_selection,
         true <- record.evidence == build_evidence(record) do
      {:ok, record}
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_execution_policy_record}
    end
  end

  def validate(_record), do: {:error, :invalid_execution_policy_record}

  @doc "Returns stable policy evidence without executable adapter data."
  @spec evidence(t()) :: map()
  def evidence(%__MODULE__{evidence: evidence}), do: evidence

  @doc false
  @spec build_evidence(t()) :: map()
  def build_evidence(%__MODULE__{} = record) do
    build_evidence(
      record.execution_policy_id,
      record.security_profile,
      record.adapter_capabilities,
      record.registration,
      record.jidoka_selection
    )
  end

  @doc false
  @spec build_evidence(
          String.t(),
          SecurityProfile.t(),
          AdapterCapabilities.t(),
          Registration.t(),
          Selection.t()
        ) :: map()
  def build_evidence(id, profile, capabilities, registration, selection) do
    subject = %{
      "contract" => "jido_console.execution_policy.evidence.v1",
      "execution_policy_id" => id,
      "profile" => SecurityProfile.to_map(profile),
      "capabilities" => AdapterCapabilities.to_map(capabilities),
      "registration_fingerprint" => registration.fingerprint,
      "selection_fingerprint" => selection.fingerprint,
      "adapter_module" => Atom.to_string(registration.adapter)
    }

    %{
      "execution_policy_id" => id,
      "profile_revision" => profile.revision,
      "profile_digest" => profile.digest,
      "adapter_id" => capabilities.adapter_id,
      "adapter_version" => capabilities.adapter_version,
      "registration_fingerprint" => registration.fingerprint,
      "selection_fingerprint" => selection.fingerprint,
      "evidence_digest" => ExecutionEnvironment.digest(subject)
    }
  end

  @doc "Projects safe, stable registry data for display and storage."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = record) do
    %{
      "execution_policy_id" => record.execution_policy_id,
      "class" => Atom.to_string(record.class),
      "warning" => record.warning,
      "requires_workspace_root" => record.requires_workspace_root?,
      "evidence" => record.evidence,
      "selection" => Selection.to_map(record.jidoka_selection)
    }
  end
end
