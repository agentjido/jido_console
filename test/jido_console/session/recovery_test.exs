defmodule Jido.Console.Session.RecoveryTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Delivery, Recovery, State}

  test "snapshot recovery is not described as durable resume" do
    {:ok, delivery, _state} =
      Recovery.recover(State.new("ses_1"), Delivery.new(client_id: "cli", session_id: "ses_1"), [])

    assert delivery.session_id == "ses_1"
    assert Recovery.limitation() =~ "not application-restart"
  end
end
