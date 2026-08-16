defmodule Jido.Console.Tui.Shutdown do
  @moduledoc """
  Stops renderer-local workers without stopping session-owned work.

  The TUI detaches from `Session.Client`. The supervised session owns runtime
  cancellation and cleanup after that point.
  """

  alias Jido.Console.Tui.Workers

  @timeout_ms 250

  @spec run(Jido.Console.Tui.State.t(), Workers.t(), module(), keyword()) :: :ok
  def run(_state, workers, _runtime, opts) do
    Workers.stop_all(workers, option_timeout(opts, :shutdown_timeout_ms, @timeout_ms))
  end

  defp option_timeout(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _other -> default
    end
  end
end
