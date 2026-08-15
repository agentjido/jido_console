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
end
