defmodule Jido.Console.Session.ConcurrencyTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{Command, Server, Supervisor}
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor
  alias Jido.Console.Test.{ThreadBridge, ThreadResources}

  setup do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "jido-thread-concurrency-#{suffix}")
    writer = unique(:writer, suffix)
    registry = unique(:registry, suffix)
    sessions = unique(:sessions, suffix)
    tasks = unique(:tasks, suffix)

    {:ok, storage} =
      StorageSupervisor.start_link(
        name: unique(:storage_supervisor, suffix),
        writer: writer,
        lock: unique(:lock, suffix),
        jido_home: root
      )

    {:ok, supervisor} =
      Supervisor.start_link(
        name: unique(:session_supervisor, suffix),
        registry: registry,
        sessions: sessions,
        tasks: tasks
      )

    opts = [
      registry: registry,
      supervisor: sessions,
      tasks: tasks,
      writer: writer,
      deadline: 5_000,
      resources_module: ThreadResources,
      bridge_module: ThreadBridge,
      test_pid: self()
    ]

    on_exit(fn ->
      if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
      if Process.alive?(storage), do: Process.exit(storage, :shutdown)
      File.rm_rf(root)
    end)

    %{opts: opts}
  end

  test "concurrent open calls converge on one owner", %{opts: opts} do
    owners =
      1..20
      |> Enum.map(fn _index -> Task.async(fn -> Server.ensure_started("one-owner", opts) end) end)
      |> Task.await_many(10_000)
      |> Enum.map(fn {:ok, owner} -> owner end)

    assert owners |> Enum.uniq() |> length() == 1
  end

  test "different thread owners enter provider work independently", %{opts: opts} do
    {:ok, owner_a} = Server.ensure_started("thread-a", opts)
    {:ok, owner_b} = Server.ensure_started("thread-b", opts)

    task_a = Task.async(fn -> Server.command(owner_a, command("thread-a", "a")) end)
    task_b = Task.async(fn -> Server.command(owner_b, command("thread-b", "b")) end)
    assert {:ok, _accepted} = Task.await(task_a)
    assert {:ok, _accepted} = Task.await(task_b)

    starts =
      for _index <- 1..2 do
        assert_receive {:provider_started, thread_id, request_id, bridge}
        {thread_id, request_id, bridge}
      end

    assert starts |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["thread-a", "thread-b"]
    Enum.each(starts, fn {_thread, _request, bridge} -> send(bridge, :finish) end)
  end

  defp command(thread_id, suffix) do
    Command.new!(
      id: "command-#{suffix}",
      type: :submit,
      thread_id: thread_id,
      queue_item_id: "command-#{suffix}",
      request_id: "request-#{suffix}",
      text: "prompt-#{suffix}",
      payload: %{}
    )
  end

  defp unique(label, suffix), do: String.to_atom("#{label}-#{suffix}")
end
