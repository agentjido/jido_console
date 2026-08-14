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

  test "keeps the request owner alive until the request is complete" do
    test_pid = self()

    workers =
      Workers.start_turn(%{}, fn _relay_pid ->
        send(test_pid, {:request_owner, self()})
        {:ok, :request}
      end)

    assert_receive {:request_owner, owner}
    assert_receive {:jido_tui_effect_result, ^owner, {:ok, {:ok, :request}}}
    assert Process.alive?(owner)

    assert {:ok, worker, workers} = Workers.take_completion(workers, owner)
    workers = Workers.promote_request_owner(workers, worker.pid, :request)
    assert workers[owner].kind == :request_owner
    assert workers[owner].subject == :request

    workers = Workers.stop_subject(workers, :request)
    refute Process.alive?(owner)
    assert :ok = Workers.stop_all(workers, 100)
  end
end
