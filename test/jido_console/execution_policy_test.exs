defmodule Jido.Console.ExecutionPolicyTest do
  use ExUnit.Case, async: false

  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.ExecutionPolicy.Consent

  test "uses canonical policy IDs and normalizes the local compatibility alias" do
    assert ExecutionPolicy.restricted_id() == "coding.restricted"
    assert ExecutionPolicy.trusted_id() == "coding.trusted-workspace"
    assert ExecutionPolicy.normalize_id("coding.local") == "coding.trusted-workspace"
    assert ExecutionPolicy.normalize_id(" coding.restricted ") == "coding.restricted"
  end

  test "mints broader consent only for a direct human input origin" do
    for origin <- [:cli, :api, :tui] do
      assert {:ok,
              %Consent{
                execution_policy_id: "coding.trusted-workspace",
                origin: ^origin
              }} = ExecutionPolicy.direct_choice("coding.local", origin)
    end

    for origin <- [:application, :agent, :document, :default, :tui_default] do
      assert {:error, {:invalid_execution_policy_consent_origin, ^origin}} =
               ExecutionPolicy.direct_choice("coding.trusted-workspace", origin)
    end
  end

  test "rejects canonical and legacy input conflicts before keyword conversion" do
    assert {:error, :conflicting_execution_policy_inputs} =
             ExecutionPolicy.direct_choice(
               [execution_policy: "coding.restricted", coding_profile: "coding.restricted"],
               :cli
             )

    assert {:error, :repeated_execution_policy_input} =
             ExecutionPolicy.direct_choice(
               [execution_policy: "coding.restricted", execution_policy: "coding.restricted"],
               :cli
             )

    assert {:ok, %Consent{execution_policy_id: "coding.trusted-workspace", legacy?: true}} =
             ExecutionPolicy.direct_choice([coding_profile: "coding.local"], :api)
  end

  test "reads a legacy application value only as a normalized proposal" do
    canonical = Application.fetch_env(:jido_console, :execution_policy)
    legacy = Application.fetch_env(:jido_console, :coding_profile)

    on_exit(fn ->
      restore_env(:execution_policy, canonical)
      restore_env(:coding_profile, legacy)
    end)

    Application.delete_env(:jido_console, :execution_policy)
    Application.put_env(:jido_console, :coding_profile, "coding.local")
    assert {:ok, "coding.trusted-workspace"} = ExecutionPolicy.application_proposal()

    Application.put_env(:jido_console, :execution_policy, "coding.trusted-workspace")
    assert {:error, :conflicting_execution_policy_inputs} = ExecutionPolicy.application_proposal()
  end

  test "agent input can create only a data-only Jidoka policy request" do
    assert {:ok, request} = ExecutionPolicy.policy_request("coding.local")
    assert %Jidoka.ExecutionEnvironment.PolicyRequest{} = request
    assert request.profile_id == "coding.trusted-workspace"

    for forged <- [
          %{execution_profile: "coding.trusted-workspace", consent: true},
          %{profile_id: "coding.trusted-workspace", adapter: SomeAdapter},
          %{execution_policy_id: "coding.trusted-workspace", registration: %{}},
          %Consent{execution_policy_id: "coding.trusted-workspace", origin: :agent, legacy?: false}
        ] do
      assert {:error, :invalid_agent_execution_policy_request} =
               ExecutionPolicy.policy_request(forged)
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:jido_console, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:jido_console, key)
end
