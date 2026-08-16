defmodule Jido.Console.Session.HookTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Hook

  test "authority hooks fail closed and descriptors do not load extensions" do
    assert {:ok, _} =
             Hook.validate(%{
               "id" => "ext_1",
               "version" => "1",
               "capabilities" => [],
               "hooks" => ["authorize"],
               "input_schema" => %{},
               "output_schema" => %{},
               "provenance" => %{},
               "trust" => %{}
             })

    assert {:error, {:authority_hook_failed, "authorize", :denied}} = Hook.fail("authorize", :denied)
    assert {:ok, %{"visible" => true}} = Hook.fail("observe", :timeout)
    refute Hook.loads_extensions?()
  end

  test "rejects invalid descriptors, authority fields, and unknown hooks" do
    assert {:error, :invalid_descriptor} = Hook.validate(:invalid)
    assert {:error, :incomplete_descriptor} = Hook.validate(%{})

    descriptor = %{
      "id" => "extension",
      "version" => "1",
      "capabilities" => [],
      "hooks" => [],
      "input_schema" => %{},
      "output_schema" => %{},
      "provenance" => %{},
      "trust" => %{},
      "permission" => "all"
    }

    assert {:error, {:unknown_authority_field, ["permission"]}} = Hook.validate(descriptor)
    assert {:ok, %{"visible" => true}} = Hook.fail("annotate", :failed)
    assert {:error, {:authority_hook_failed, "approve", :failed}} = Hook.fail("approve", :failed)
    assert {:error, {:unknown_hook, "other"}} = Hook.fail("other", :failed)
  end
end
