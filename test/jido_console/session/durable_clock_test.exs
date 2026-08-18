defmodule Jido.Console.Session.DurableClockTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.DurableClock

  defmodule FixedClock do
    def now_ms, do: 123
  end

  test "accepts functions and modules and rejects invalid clocks" do
    assert {:ok, 45} = DurableClock.now_ms(fn -> 45 end)
    assert {:ok, 123} = DurableClock.now_ms(FixedClock)
    assert {:ok, now} = DurableClock.now_ms(DurableClock)
    assert now > 0
    assert {:error, :invalid_durable_clock} = DurableClock.now_ms(String)
    assert {:error, :invalid_durable_clock} = DurableClock.now_ms(:not_a_clock)
    assert {:error, :invalid_durable_clock} = DurableClock.now_ms(fn -> -1 end)
    assert {:error, :invalid_durable_clock} = DurableClock.now_ms(%{})
  end
end
