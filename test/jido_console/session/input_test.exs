defmodule Jido.Console.Session.InputTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Identity, Input}

  test "an input value carries its durable key and stable identity before wake-up" do
    assert {:error, :idempotency_key_required} =
             Input.admit("hello", session_id: Identity.new!(:session).id)

    {:ok, input} =
      Input.admit("hello",
        session_id: Identity.new!(:session).id,
        idempotency_key: "input-value"
      )

    assert input.status == :accepted
    assert input.idempotency_key == "input-value"
    assert Input.wakeup(input).text == input.text
    assert {:ok, %{status: :started}} = Input.transition(input, :started)
    assert {:error, {:invalid_input_status, :unknown}} = Input.transition(input, :unknown)
    assert Input.crash_limitation() =~ "survives an application restart"
    assert Input.crash_limitation() =~ "recoverable work"
  end
end
