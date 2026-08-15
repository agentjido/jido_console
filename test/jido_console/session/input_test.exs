defmodule Jido.Console.Session.InputTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Identity, Input}

  test "accepted input has an identity before wake-up and crash loss is documented" do
    {:ok, input} = Input.admit("hello", session_id: Identity.new!(:session).id)
    assert input.status == :accepted
    assert Input.wakeup(input).text == input.text
    assert Input.crash_limitation() =~ "Milestone 3"
  end
end
