defmodule Jido.Console.Session.DeliveryTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Delivery

  test "a slow client gets an explicit gap instead of unbounded pending updates" do
    delivery = Delivery.new(client_id: "cli_1", session_id: "ses_1", bound: 1)
    {:ok, delivery, _} = Delivery.offer(delivery, %{"sequence" => 1})
    assert {:gap, gapped, gap} = Delivery.offer(delivery, %{"sequence" => 2})
    assert gapped.status == :gapped
    refute Map.has_key?(gapped, :pending)
    refute Map.has_key?(gapped, :highest_offered)
    assert gap["type"] == "delivery_gap"
  end

  test "safe updates coalesce before the bound forces a gap" do
    delivery = Delivery.new(client_id: "cli_1", session_id: "ses_1", bound: 1)
    first = %{"sequence" => 1, "coalesce" => true, "text" => "a"}
    second = %{"sequence" => 2, "coalesce" => true, "text" => "ab"}

    {:ok, delivery, _} = Delivery.offer(delivery, first)
    assert {:ok, delivery, ^second} = Delivery.offer(delivery, second)
    assert delivery.pending == [second]
    assert delivery.status == :open
    assert delivery.highest_offered == 2
  end

  test "unsafe updates still gap when the bound is full" do
    delivery = Delivery.new(client_id: "cli_1", session_id: "ses_1", bound: 1)
    {:ok, delivery, _} = Delivery.offer(delivery, %{"sequence" => 1, "coalesce" => true})
    assert {:gap, gapped, gap} = Delivery.offer(delivery, %{"sequence" => 2})
    assert gapped.status == :gapped
    assert gap["current_sequence"] == 2
    assert {:gap, ^gapped, nil} = Delivery.offer(gapped, %{"sequence" => 3})
  end

  test "acknowledgements cannot advance past the highest offered sequence" do
    delivery = Delivery.new(client_id: "cli_1", session_id: "ses_1")
    {:ok, delivery, _update} = Delivery.offer(delivery, %{"sequence" => 2})

    assert {:error, :future_ack} = Delivery.ack(delivery, "cli_1", "ses_1", 3)
    assert {:ok, acknowledged} = Delivery.ack(delivery, "cli_1", "ses_1", 2)
    assert acknowledged.last_acked == 2
    assert acknowledged.pending == []
  end

  test "acknowledgement cannot clear a delivery gap" do
    delivery = Delivery.new(client_id: "cli_1", session_id: "ses_1", bound: 1)
    {:ok, delivery, _update} = Delivery.offer(delivery, %{"sequence" => 1})
    {:gap, gapped, _gap} = Delivery.offer(delivery, %{"sequence" => 2})

    assert {:error, :delivery_gapped} = Delivery.ack(gapped, "cli_1", "ses_1", 1)
    assert gapped.status == :gapped
  end
end
