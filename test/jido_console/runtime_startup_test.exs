defmodule Jido.Console.RuntimeStartupTest do
  use ExUnit.Case, async: true

  alias Jido.Console.RuntimeStartup

  test "rejects a startup value that is not a zero-arity function" do
    assert RuntimeStartup.invoke(application_startup: :invalid) ==
             {:error, :invalid_application_startup}
  end

  test "returns raised, thrown, and exited startup failures" do
    assert {:error, %ArgumentError{message: "startup failed"}} =
             RuntimeStartup.invoke(application_startup: fn -> raise ArgumentError, "startup failed" end)

    assert RuntimeStartup.invoke(application_startup: fn -> throw(:startup_failed) end) ==
             {:error, {:throw, :startup_failed}}

    assert RuntimeStartup.invoke(application_startup: fn -> exit(:startup_failed) end) ==
             {:error, {:exit, :startup_failed}}
  end
end
