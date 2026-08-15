defmodule Jido.Console.Session.DeliveryTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Delivery

  test "a slow client gets an explicit gap instead of unbounded pending updates" do
    delivery = Delivery.new(client_id: "cli_1", session_id: "ses_1", bound: 1)
    {:ok, delivery, _} = Delivery.offer(delivery, %{"sequence" => 1})
    assert {:gap, _, gap} = Delivery.offer(delivery, %{"sequence" => 2})
    assert gap["type"] == "delivery_gap"
  end
end
