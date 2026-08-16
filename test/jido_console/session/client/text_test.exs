defmodule Jido.Console.Session.Client.TextTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Client.Text

  test "ordered outcomes, gaps, and errors have deterministic text" do
    text =
      Text.transcript([
        %{"type" => "run_started"},
        %{"type" => "delivery_gap", "last_acknowledged" => 3},
        %{"type" => "run_failed", "reason" => "boom"}
      ])

    assert text == "run_started\ngap after 3\nerror: boom"
    refute text =~ "#PID"
  end

  test "uses nested and fallback failure reasons" do
    assert Text.render(%{"type" => "delivery_gap"}) == "gap after 0"
    assert Text.render(%{"type" => "run_failed", "payload" => %{"reason" => "nested"}}) == "error: nested"
    assert Text.render(%{"type" => "run_failed"}) == "error: failed"
    assert Text.render(:invalid) == "unknown"
  end
end
