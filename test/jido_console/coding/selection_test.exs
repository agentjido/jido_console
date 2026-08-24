defmodule Jido.Console.Coding.SelectionTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Coding.Selection

  test "keeps pack and execution policy selections independent" do
    for disabled <- [false, :disabled, "disabled", nil] do
      assert {:ok,
              %{
                pack_id: nil,
                execution_policy_id: "coding.restricted",
                profile_id: "coding.restricted"
              }} = Selection.resolve(coding_pack: disabled)
    end

    assert {:ok,
            %{
              pack_id: "acme.pack",
              execution_policy_id: "coding.trusted-workspace",
              profile_id: "coding.trusted-workspace"
            }} = Selection.resolve(coding_pack: "acme.pack", coding_profile: "coding.local")

    assert {:error, {:invalid_coding_pack, true}} = Selection.resolve(coding_pack: true)

    assert {:error, {:invalid_execution_policy, false}} =
             Selection.resolve(coding_pack: "acme.pack", coding_profile: false)

    assert {:error, :conflicting_execution_policy_inputs} =
             Selection.resolve(
               execution_policy: "coding.restricted",
               coding_profile: "coding.restricted"
             )

    for forbidden <- ["Elixir.Module", ":module", "path/module"] do
      assert {:error, :coding_module_name_forbidden} =
               Selection.resolve(coding_pack: forbidden, coding_profile: "profile")
    end
  end

  test "normalizes canonical and compatibility resolver results" do
    assert :ok = Selection.validate_execution_policy("policy", [])

    assert :ok =
             Selection.validate_execution_policy("policy",
               execution_policy_resolver: fn _id -> :ok end
             )

    assert :ok =
             Selection.validate_profile("policy", coding_profile_resolver: fn _id -> {:ok, %{}} end)

    assert {:error, {:unknown_execution_policy, "policy", :missing}} =
             Selection.validate_execution_policy("policy",
               coding_profile_resolver: fn _id -> {:error, :missing} end
             )

    assert {:error, {:unknown_execution_policy, "policy"}} =
             Selection.validate_execution_policy("policy",
               coding_profile_resolver: fn _id -> :invalid end
             )

    assert {:error, :invalid_execution_policy_resolver} =
             Selection.validate_execution_policy("policy", coding_profile_resolver: :invalid)

    assert {:error, :conflicting_execution_policy_inputs} =
             Selection.validate_execution_policy("policy",
               execution_policy_resolver: fn _id -> :ok end,
               coding_profile_resolver: fn _id -> :ok end
             )
  end
end
