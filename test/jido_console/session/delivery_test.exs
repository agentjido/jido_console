defmodule Jido.Console.Session.DeliveryTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Delivery

  test "a slow client gets an explicit gap instead of unbounded pending updates" do
    delivery = Delivery.new(client_id: "cli_1", session_id: "ses_1", bound: 1)
    {:ok, delivery, _} = Delivery.offer(delivery, %{"sequence" => 1})
    assert {:gap, _, gap} = Delivery.offer(delivery, %{"sequence" => 2})
    assert gap["type"] == "delivery_gap"
  end

  test "safe updates coalesce before the bound forces a gap" do
    delivery = Delivery.new(client_id: "cli_1", session_id: "ses_1", bound: 1)
    first = %{"sequence" => 1, "coalesce" => true, "text" => "a"}
    second = %{"sequence" => 2, "coalesce" => true, "text" => "ab"}

    {:ok, delivery, _} = Delivery.offer(delivery, first)
    assert {:ok, delivery, ^second} = Delivery.offer(delivery, second)
    assert delivery.pending == [second]
    refute delivery.gap?
  end

  test "unsafe updates still gap when the bound is full" do
    delivery = Delivery.new(client_id: "cli_1", session_id: "ses_1", bound: 1)
    {:ok, delivery, _} = Delivery.offer(delivery, %{"sequence" => 1, "coalesce" => true})
    assert {:gap, gapped, gap} = Delivery.offer(delivery, %{"sequence" => 2})
    assert gapped.gap?
    assert gap["current_sequence"] == 2
  end
end
