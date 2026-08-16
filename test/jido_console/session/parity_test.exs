defmodule Jido.Console.Session.ParityTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Parity

  test "current clients observe the same ordered outcome types" do
    events = [
      %{"type" => "run_started", "sequence" => 1},
      %{"type" => "run_completed", "sequence" => 2}
    ]

    assert Parity.same_outcomes?(events)
    observed = Parity.observe(events)
    assert observed.tui == ["run_started", "run_completed"]
    assert observed.automation == observed.tui
    assert observed.json == observed.tui
  end
end
