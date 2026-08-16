defmodule Jido.Console.Session.RecoveryTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Delivery, Recovery, State}

  test "only an explicit gap can recover from the owner snapshot" do
    state = %{State.new("ses_1") | sequence: 2}
    open = Delivery.new(client_id: "cli", session_id: "ses_1", bound: 1)
    {:ok, open, _update} = Delivery.offer(open, %{"sequence" => 1})
    {:gap, gapped, _gap} = Delivery.offer(open, %{"sequence" => 2})

    assert {:error, :recovery_not_required} =
             Recovery.recover(state, Delivery.new(client_id: "cli", session_id: "ses_1"))

    assert {:ok, delivery, ^state} = Recovery.recover(state, gapped)

    assert delivery.status == :open
    assert delivery.session_id == "ses_1"
    assert delivery.pending == []
    assert delivery.last_acked == 2
    assert delivery.highest_offered == 2
    assert Recovery.limitation() =~ "not application-restart"
  end

  test "recovery rejects a delivery state from another session" do
    state = State.new("ses_1")
    open = Delivery.new(client_id: "cli", session_id: "ses_2", bound: 1)
    {:ok, open, _update} = Delivery.offer(open, %{"sequence" => 1})
    {:gap, gapped, _gap} = Delivery.offer(open, %{"sequence" => 2})

    assert {:error, :cross_session_result} = Recovery.recover(state, gapped)
  end
end
