defmodule Jido.Console.Session.DurableClock do
  @moduledoc """
  Injected wall clock for durable expiry decisions.

  A replay uses the persisted decision event. It does not read this clock.
  """

  @type clock :: module() | (-> non_neg_integer())

  @doc "Returns the current wall-clock time in milliseconds."
  @spec now_ms(clock()) :: {:ok, non_neg_integer()} | {:error, :invalid_durable_clock}
  def now_ms(clock) when is_function(clock, 0), do: validate(clock.())

  def now_ms(clock) when is_atom(clock) do
    if Code.ensure_loaded?(clock) and function_exported?(clock, :now_ms, 0) do
      validate(clock.now_ms())
    else
      {:error, :invalid_durable_clock}
    end
  end

  def now_ms(_clock), do: {:error, :invalid_durable_clock}

  @doc false
  @spec now_ms() :: non_neg_integer()
  def now_ms, do: System.system_time(:millisecond)

  defp validate(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp validate(_value), do: {:error, :invalid_durable_clock}
end
