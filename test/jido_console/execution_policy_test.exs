defmodule Jido.Console.ExecutionPolicyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.ExecutionPolicy.Consent

  test "uses canonical policy IDs and normalizes the local compatibility alias" do
    assert ExecutionPolicy.restricted_id() == "coding.restricted"
    assert ExecutionPolicy.trusted_id() == "coding.trusted-workspace"
    assert ExecutionPolicy.normalize_id("coding.local") == "coding.trusted-workspace"
    assert ExecutionPolicy.normalize_id(" coding.restricted ") == "coding.restricted"
    assert ExecutionPolicy.trusted_alias() == "coding.local"
    assert ExecutionPolicy.trusted_warning() == "Trusted-workspace mode is not a sandbox."
    assert ExecutionPolicy.legacy_warning() == "coding profile is deprecated; use execution policy"
    assert ExecutionPolicy.environment_allowlist() == ~w(PATH LANG TERM TMPDIR HOME)
    assert ExecutionPolicy.normalize_id(nil) == nil
    assert ExecutionPolicy.normalize_id(:unchanged) == :unchanged
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

    warning =
      capture_log(fn ->
        assert {:ok, "coding.trusted-workspace"} = ExecutionPolicy.application_proposal()
      end)

    assert warning =~ "coding profile is deprecated; use execution policy"
    assert length(String.split(warning, "coding profile is deprecated; use execution policy")) - 1 == 1

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

    assert {:error, :invalid_agent_execution_policy_request} = ExecutionPolicy.policy_request("")
  end

  test "validates direct choices, resolvers, and stored consent inputs" do
    assert {:ok, nil} = ExecutionPolicy.direct_choice([], :api)
    assert {:error, {:invalid_execution_policy_input, ""}} = ExecutionPolicy.direct_choice("", :api)
    assert {:error, {:invalid_execution_policy_input, 1}} = ExecutionPolicy.direct_choice(1, :api)

    assert {:error, {:invalid_execution_policy_consent_origin, :agent}} =
             ExecutionPolicy.direct_choice(1, :agent)

    assert {:error, {:invalid_execution_policy_input, 1}} =
             ExecutionPolicy.direct_choice([execution_policy: 1], :api)

    assert {:error, :invalid_execution_policy_input_layer} =
             ExecutionPolicy.direct_choice([:not_a_keyword], :api)

    assert {:error, :invalid_execution_policy_input_layer} = ExecutionPolicy.resolver_from_layer(:invalid)
    assert {:ok, nil} = ExecutionPolicy.resolver_from_layer([])
    refute ExecutionPolicy.valid_direct_consent?(:invalid)
    refute ExecutionPolicy.valid_stored_consent?(:invalid)
    assert {:error, :invalid_execution_policy_selection} = ExecutionPolicy.store_consent(:invalid, "thread")
    assert {:error, :invalid_execution_policy_selection} = ExecutionPolicy.store_consent(:invalid, "")
  end

  test "validates canonical application proposals" do
    canonical = Application.fetch_env(:jido_console, :execution_policy)
    legacy = Application.fetch_env(:jido_console, :coding_profile)

    on_exit(fn ->
      restore_env(:execution_policy, canonical)
      restore_env(:coding_profile, legacy)
    end)

    Application.delete_env(:jido_console, :coding_profile)

    for {value, expected} <- [
          {"coding.local", {:ok, "coding.trusted-workspace"}},
          {nil, {:ok, nil}},
          {"", {:error, {:invalid_execution_policy_input, ""}}},
          {1, {:error, {:invalid_execution_policy_input, 1}}}
        ] do
      Application.put_env(:jido_console, :execution_policy, value)
      assert ExecutionPolicy.application_proposal() == expected
    end

    Application.delete_env(:jido_console, :execution_policy)
    assert {:ok, nil} = ExecutionPolicy.application_proposal()
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:jido_console, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:jido_console, key)
end
