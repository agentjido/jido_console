defmodule Jido.Console.Coding.SelectionTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Coding.Selection

  test "normalizes disabled and trusted coding selections" do
    for disabled <- [false, :disabled, "disabled", nil] do
      assert {:ok, %{pack_id: nil, profile_id: nil}} = Selection.resolve(coding_pack: disabled)
    end

    assert {:ok, %{pack_id: "pack", profile_id: "profile"}} =
             Selection.resolve(coding_pack: "pack", coding_profile: "profile")

    assert {:error, {:invalid_coding_pack, true}} = Selection.resolve(coding_pack: true)
    assert {:error, {:invalid_execution_profile, false}} = Selection.resolve(coding_pack: "pack", coding_profile: false)

    for forbidden <- ["Elixir.Module", ":module", "path/module"] do
      assert {:error, :coding_module_name_forbidden} =
               Selection.resolve(coding_pack: forbidden, coding_profile: "profile")
    end
  end

  test "normalizes each profile resolver result" do
    assert :ok = Selection.validate_profile("profile", [])
    assert :ok = Selection.validate_profile("profile", coding_profile_resolver: fn _id -> :ok end)
    assert :ok = Selection.validate_profile("profile", coding_profile_resolver: fn _id -> {:ok, %{}} end)

    assert {:error, {:unknown_runtime_profile, "profile", :missing}} =
             Selection.validate_profile("profile", coding_profile_resolver: fn _id -> {:error, :missing} end)

    assert {:error, {:unknown_runtime_profile, "profile"}} =
             Selection.validate_profile("profile", coding_profile_resolver: fn _id -> :invalid end)

    assert {:error, :invalid_coding_profile_resolver} =
             Selection.validate_profile("profile", coding_profile_resolver: :invalid)
  end
end
