defmodule RateLimiterTest do
  use ExUnit.Case, async: true

  test "accepts events until the limit is reached" do
    assert {true, [30, 20, 10]} = RateLimiter.allow?([20, 10], 30, 3, 100)
  end

  test "rejects an event at the limit and does not store it" do
    assert {false, [30, 20, 10]} = RateLimiter.allow?([30, 20, 10], 40, 3, 100)
  end

  test "removes a timestamp exactly at the cutoff" do
    assert {true, [110, 60]} = RateLimiter.allow?([60, 10], 110, 2, 100)
  end
end
