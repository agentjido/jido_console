defmodule Jido.Console.Session.RecoveryTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Delivery, Recovery, State}

  test "only an explicit gap can recover from the owner snapshot" do
    state = %{State.new("ses_1") | sequence: 2}
    open = Delivery.new(client_id: "cli", session_id: "ses_1", attachment_id: "att_1")
    gapped = %{open | status: :gapped}

    assert {:error, :recovery_not_required} =
             Recovery.recover(
               state,
               Delivery.new(client_id: "cli", session_id: "ses_1", attachment_id: "att_1")
             )

    assert {:ok, delivery, ^state} = Recovery.recover(state, gapped)

    assert delivery.status == :open
    assert delivery.session_id == "ses_1"
    assert delivery.queue == []
    assert delivery.last_acked == 2
    assert Recovery.limitation() =~ "not application-restart"
  end

  test "recovery rejects a delivery state from another session" do
    state = State.new("ses_1")
    open = Delivery.new(client_id: "cli", session_id: "ses_2", attachment_id: "att_2")
    gapped = %{open | status: :gapped}

    assert {:error, :cross_session_result} = Recovery.recover(state, gapped)
  end
end
