defmodule Jido.Cli.Tui.WorkersTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Tui.Workers

  test "stops and reaps every tracked worker within the bound" do
    previous_trap_exit = Process.flag(:trap_exit, true)
    test_pid = self()

    try do
      workers =
        Workers.start(%{}, :blocked, nil, fn ->
          send(test_pid, {:worker_blocked, self()})
          receive do: (:never -> :ok)
        end)

      assert_receive {:worker_blocked, worker}
      assert Process.alive?(worker)
      assert :ok = Workers.stop_all(workers, 100)
      refute Process.alive?(worker)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end
end
