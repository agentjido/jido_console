defmodule Jido.Console.Tui.WorkersTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.Workers

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

  test "tracks and completes one generic monitored worker" do
    test_pid = self()

    workers =
      Workers.start(%{}, :example, :unused_subject, fn ->
        send(test_pid, {:effect_worker, self()})
        :done
      end)

    assert_receive {:effect_worker, worker_pid}
    assert_receive {:jido_tui_effect_result, ^worker_pid, {:ok, :done}}
    assert %Workers.Worker{pid: ^worker_pid, ref: ref, kind: :example} = workers[worker_pid]
    assert is_reference(ref)
    refute Map.has_key?(workers[worker_pid], :subject)

    assert {:ok, %Workers.Worker{pid: ^worker_pid}, remaining} =
             Workers.take_completion(workers, worker_pid)

    assert remaining == %{}
    assert :error = Workers.take_completion(remaining, worker_pid)
  end

  test "takes DOWN before a late result without keeping stale worker state" do
    test_pid = self()

    workers =
      Workers.start(%{}, :example, nil, fn ->
        send(test_pid, {:effect_worker, self()})
        :done
      end)

    assert_receive {:effect_worker, worker_pid}
    worker = workers[worker_pid]

    assert {:ok, ^worker, remaining} = Workers.take_down(workers, worker_pid, worker.ref)
    assert remaining == %{}
    assert :error = Workers.take_completion(remaining, worker_pid)
    assert :error = Workers.take_down(remaining, worker_pid, worker.ref)
    assert_receive {:jido_tui_effect_result, ^worker_pid, {:ok, :done}}
  end

  test "ignores DOWN after a completed result removes the worker" do
    workers = Workers.start(%{}, :example, nil, fn -> :done end)
    [{worker_pid, worker}] = Map.to_list(workers)

    assert_receive {:jido_tui_effect_result, ^worker_pid, {:ok, :done}}
    assert {:ok, ^worker, remaining} = Workers.take_completion(workers, worker_pid)
    assert remaining == %{}
    assert :error = Workers.take_down(remaining, worker_pid, worker.ref)
  end

  test "records crashes as effect results" do
    workers = Workers.start(%{}, :example, nil, fn -> raise "failed effect" end)
    [{worker_pid, worker}] = Map.to_list(workers)

    assert_receive {:jido_tui_effect_result, ^worker_pid, {:crash, %RuntimeError{message: "failed effect"}}}

    assert {:ok, ^worker, %{}} = Workers.take_completion(workers, worker_pid)
  end

  test "stops one tracked worker and removes it" do
    previous_trap_exit = Process.flag(:trap_exit, true)
    test_pid = self()

    try do
      workers =
        Workers.start(%{}, :blocked, nil, fn ->
          send(test_pid, {:worker_blocked, self()})
          receive do: (:never -> :ok)
        end)

      assert_receive {:worker_blocked, worker_pid}
      assert Workers.stop(workers, worker_pid) == %{}
      refute Process.alive?(worker_pid)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end
end
