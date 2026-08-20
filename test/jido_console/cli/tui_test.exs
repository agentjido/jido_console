defmodule Jido.Console.TuiTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.Supervisor
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor
  alias Jido.Console.Test.{TermUIBackend, ThreadBridge, ThreadResources}
  alias Jido.Console.Tui

  setup do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "jido-tui-#{suffix}")
    writer = unique(:writer, suffix)
    registry = unique(:registry, suffix)
    sessions = unique(:sessions, suffix)
    tasks = unique(:tasks, suffix)
    session_supervisor_name = unique(:session_supervisor, suffix)
    {:ok, event_queue} = Agent.start_link(fn -> :queue.new() end)

    {:ok, storage} =
      StorageSupervisor.start_link(
        name: unique(:storage_supervisor, suffix),
        writer: writer,
        lock: unique(:lock, suffix),
        jido_home: root
      )

    {:ok, session_supervisor} =
      Supervisor.start_link(
        name: session_supervisor_name,
        registry: registry,
        sessions: sessions,
        tasks: tasks
      )

    opts = [
      name: session_supervisor_name,
      registry: registry,
      sessions: sessions,
      tasks: tasks,
      writer: writer,
      deadline: 5_000,
      resources_module: ThreadResources,
      bridge_module: ThreadBridge,
      test_pid: self(),
      term_ui_backend: TermUIBackend,
      term_ui_backend_opts: [test_pid: self(), event_queue: event_queue, size: {16, 60}],
      application_startup: fn -> :ok end,
      process_register: fn _kind, _pid, _opts -> {:ok, %{}} end,
      process_stop: fn _id, _opts -> :ok end,
      catalog_entries: [
        %{identity: "test:model", provider: "test", model: "model", tier: :supported}
      ]
    ]

    on_exit(fn ->
      if Process.alive?(session_supervisor), do: Process.exit(session_supervisor, :shutdown)
      if Process.alive?(storage), do: Process.exit(storage, :shutdown)
      File.rm_rf(root)
    end)

    %{opts: opts, event_queue: event_queue}
  end

  test "submits through Session.Client and exits without stopping completed work", %{
    opts: opts,
    event_queue: event_queue
  } do
    task = Task.async(fn -> Tui.run(Keyword.put(opts, :session_id, "tui-thread")) end)
    assert_receive {:term_ui_started, runtime}
    assert_receive {:frame, _initial}

    send_event(event_queue, TermUI.Event.paste("hello"))
    send_event(event_queue, TermUI.Event.key(:enter))
    assert_receive {:provider_started, "tui-thread", _request_id, bridge}, 2_000

    send_event(event_queue, TermUI.Event.paste("queued"))
    send_event(event_queue, TermUI.Event.key(:enter))
    send(bridge, :finish)
    assert_receive {:provider_started, "tui-thread", _queued_request_id, queued_bridge}, 2_000
    send(queued_bridge, :finish)
    assert_receive {:frame, _updated}, 2_000

    TermUI.Runtime.shutdown(runtime)
    assert :ok = Task.await(task, 2_000)
    assert_receive :terminal_closed
  end

  test "reports process registration failure and waits for explicit exit", %{
    opts: opts,
    event_queue: event_queue
  } do
    opts = Keyword.put(opts, :process_register, fn _kind, _pid, _opts -> {:error, :busy} end)
    task = Task.async(fn -> Tui.run(opts) end)
    assert_receive {:term_ui_started, _runtime}
    assert_receive {:frame, frame}
    assert frame =~ "startup failed"
    send_event(event_queue, TermUI.Event.key(:escape))
    assert {:error, {:process_register_failed, :busy}} = Task.await(task, 2_000)
    assert_receive :terminal_closed
  end

  test "copies a TextArea selection through the active terminal backend", %{
    opts: opts,
    event_queue: event_queue
  } do
    task = Task.async(fn -> Tui.run(Keyword.put(opts, :session_id, "clipboard-thread")) end)
    assert_receive {:term_ui_started, _runtime}
    assert_receive {:frame, _initial}

    send_event(event_queue, TermUI.Event.paste("hello"))
    send_event(event_queue, TermUI.Event.key(:left, modifiers: [:shift]))
    send_event(event_queue, TermUI.Event.key(:left, modifiers: [:shift]))
    send_event(event_queue, TermUI.Event.key("c", modifiers: [:ctrl]))

    assert_receive {:clipboard, %TermUI.Clipboard.Operation{content: "lo"}}, 2_000

    send_event(event_queue, TermUI.Event.key(:escape))
    assert :ok = Task.await(task, 2_000)
  end

  test "closes the terminal after a draw failure", %{opts: opts, event_queue: event_queue} do
    opts =
      Keyword.put(opts, :term_ui_backend_opts,
        test_pid: self(),
        event_queue: event_queue,
        fail_draw: true,
        size: {16, 60}
      )

    assert {:error, :draw_failed} = Tui.run(opts)
    assert_receive :terminal_closed
  end

  test "closes the terminal after a flush failure", %{opts: opts, event_queue: event_queue} do
    opts =
      Keyword.put(opts, :term_ui_backend_opts,
        test_pid: self(),
        event_queue: event_queue,
        fail_flush: true,
        size: {16, 60}
      )

    assert {:error, :flush_failed} = Tui.run(opts)
    assert_receive :terminal_closed
  end

  test "returns its result when process cleanup raises", %{opts: opts, event_queue: event_queue} do
    opts = Keyword.put(opts, :process_stop, fn _id, _opts -> raise "cleanup failed" end)
    task = Task.async(fn -> Tui.run(opts) end)
    assert_receive {:term_ui_started, _runtime}
    assert_receive {:frame, _initial}

    send_event(event_queue, TermUI.Event.key(:escape))

    assert :ok = Task.await(task, 2_000)
    assert_receive :terminal_closed
  end

  defp unique(label, suffix), do: String.to_atom("#{label}-#{suffix}")

  defp send_event(queue, event) do
    Agent.update(queue, &:queue.in(event, &1))
  end
end
