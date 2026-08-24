defmodule Jido.Console.TuiTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{Registry, Server, View, Supervisor}
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
        %{
          identity: "openai:gpt-4.1-mini",
          provider: "openai",
          model: "gpt-4.1-mini",
          tier: :supported
        }
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
    assert await_frame("INPUT · Enter send", 5_000)
    assert {_owner, _attachment_ref, _subscriber} = await_attachment(opts[:registry], "tui-thread")

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

  test "reattaches the same TUI after a session owner crash and restores its complete view", %{
    opts: opts,
    event_queue: event_queue
  } do
    thread_id = "owner-restart-thread"
    task = Task.async(fn -> Tui.run(Keyword.put(opts, :session_id, thread_id)) end)
    assert_receive {:term_ui_started, runtime}
    on_exit(fn -> ensure_tui_stopped(runtime, task) end)
    assert_receive {:frame, _initial}

    {owner, old_ref, subscriber} = await_attachment(opts[:registry], thread_id)
    owner_monitor = Process.monitor(owner)

    send_event(event_queue, TermUI.Event.paste("crash"))
    send_event(event_queue, TermUI.Event.key(:enter))
    assert_receive {:provider_started, ^thread_id, _request_id, _bridge}, 2_000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, {:bridge_exit, :provider_crash}}, 2_000

    {replacement, new_ref, ^subscriber} = await_attachment(opts[:registry], thread_id, owner)
    refute replacement == owner
    refute new_ref == old_ref
    assert map_size(:sys.get_state(replacement).subscribers) == 1

    assert Enum.map(Server.view(replacement).history, & &1["type"]) == [
             "prompt_queued",
             "prompt_started",
             "prompt_interrupted"
           ]

    restored_tui = :sys.get_state(subscriber).app_state.tui
    assert restored_tui.session == Server.view(replacement)
    assert List.last(restored_tui.turns).outcome.status == :interrupted

    stale =
      View.new!(
        thread_id: thread_id,
        status: :idle,
        revision: 100,
        transcript: [%{role: :assistant, content: "STALE OWNER VIEW"}]
      )

    send(subscriber, {:jido_console_view, old_ref, stale})
    send_event(event_queue, TermUI.Event.paste("later"))
    send_event(event_queue, TermUI.Event.key(:enter))
    assert_receive {:provider_started, ^thread_id, later_request, later_bridge}, 2_000
    assert is_binary(later_request)
    refute await_frame("RUNNING") =~ "STALE OWNER VIEW"
    send(later_bridge, :finish)
  end

  test "reattaches after session infrastructure replacement without duplicate subscriptions", %{
    opts: opts,
    event_queue: event_queue
  } do
    thread_id = "infrastructure-restart-thread"
    task = Task.async(fn -> Tui.run(Keyword.put(opts, :session_id, thread_id)) end)
    assert_receive {:term_ui_started, runtime}
    on_exit(fn -> ensure_tui_stopped(runtime, task) end)
    assert_receive {:frame, _initial}

    {owner, old_ref, subscriber} = await_attachment(opts[:registry], thread_id)
    owner_monitor = Process.monitor(owner)
    task_supervisor = Process.whereis(opts[:tasks])
    Process.exit(task_supervisor, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :shutdown}, 2_000

    {replacement, new_ref, ^subscriber} = await_attachment(opts[:registry], thread_id, owner)
    refute replacement == owner
    refute new_ref == old_ref
    assert map_size(:sys.get_state(replacement).subscribers) == 1

    send_event(event_queue, TermUI.Event.paste("after infrastructure restart"))
    send_event(event_queue, TermUI.Event.key(:enter))
    assert_receive {:provider_started, ^thread_id, _request_id, bridge}, 2_000
    assert await_frame("RUNNING")
    send(bridge, :finish)
  end

  test "closes command completion before the existing idle exit", %{
    opts: opts,
    event_queue: event_queue
  } do
    task = Task.async(fn -> Tui.run(Keyword.put(opts, :session_id, "completion-escape-thread")) end)
    assert_receive {:term_ui_started, runtime}, 2_000
    on_exit(fn -> ensure_tui_stopped(runtime, task) end)
    assert await_frame("INPUT · Enter send")

    send_event(event_queue, TermUI.Event.paste("/"))
    assert await_frame("> /help · Show slash commands")

    send_event(event_queue, TermUI.Event.key(:escape))

    dismissed =
      await_matching_frame(fn frame ->
        String.contains?(frame, "> /") and
          not String.contains?(frame, "/help · Show slash commands")
      end)

    assert dismissed =~ "> /"
    refute Task.yield(task, 100)

    send_event(event_queue, TermUI.Event.key(:escape))
    assert :ok = Task.await(task, 2_000)
    assert_receive :terminal_closed
  end

  test "streams safe operation lifecycle states into the supervised timeline", %{
    opts: opts,
    event_queue: event_queue
  } do
    task = Task.async(fn -> Tui.run(Keyword.put(opts, :session_id, "timeline-thread")) end)
    assert_receive {:term_ui_started, runtime}
    assert_receive {:frame, _initial}

    send_event(event_queue, TermUI.Event.paste("inspect"))
    send_event(event_queue, TermUI.Event.key(:enter))
    assert_receive {:provider_started, "timeline-thread", request_id, bridge}, 2_000

    started =
      Jidoka.Event.build(:effect_started, [],
        request_id: request_id,
        seq: 0,
        effect_id: "effect-1",
        effect_kind: :operation,
        operation: "coding.read",
        data: %{reason: "must-not-render"}
      )

    send(bridge, {:emit, started})
    running = await_frame("● RUNNING  coding.read")
    refute running =~ "must-not-render"

    completed =
      Jidoka.Event.build(:effect_completed, [],
        request_id: request_id,
        seq: 1,
        effect_id: "effect-1",
        effect_kind: :operation,
        operation: "coding.read",
        data: %{reason: "must-not-render"}
      )

    send(bridge, {:emit, completed})
    assert await_frame("✓ DONE  coding.read")

    send(bridge, :finish)
    assert await_frame("✗ FAILED")

    TermUI.Runtime.shutdown(runtime)
    assert :ok = Task.await(task, 2_000)
    assert_receive :terminal_closed
  end

  test "paints and queues input before application startup completes", %{
    opts: opts,
    event_queue: event_queue
  } do
    test_pid = self()

    startup = fn ->
      send(test_pid, {:application_startup_waiting, self()})

      receive do
        :continue_startup -> :ok
      after
        2_000 -> {:error, :startup_test_timeout}
      end
    end

    opts =
      opts
      |> Keyword.put(:application_startup, startup)
      |> Keyword.put(:session_id, "paint-first-thread")

    task = Task.async(fn -> Tui.run(opts) end)
    assert_receive {:term_ui_started, runtime}
    assert await_frame("STARTING · Enter queue") =~ "Enter queue"
    assert_receive {:application_startup_waiting, startup_pid}

    send_event(event_queue, TermUI.Event.paste("typed during startup"))
    send_event(event_queue, TermUI.Event.key(:enter))

    assert await_frame("STARTING · prompt queued") =~ "prompt queued"
    refute_receive {:provider_started, "paint-first-thread", _request_id, _bridge}, 100

    send(startup_pid, :continue_startup)
    assert_receive {:provider_started, "paint-first-thread", _request_id, bridge}, 2_000
    send(bridge, :finish)
    assert await_frame("INPUT · Enter send")

    TermUI.Runtime.shutdown(runtime)
    assert :ok = Task.await(task, 2_000)
    assert_receive :terminal_closed
  end

  test "does not submit a queued prompt cancelled during application startup", %{
    opts: opts,
    event_queue: event_queue
  } do
    test_pid = self()

    startup = fn ->
      send(test_pid, {:application_startup_waiting, self()})

      receive do
        :continue_startup -> :ok
      after
        2_000 -> {:error, :startup_test_timeout}
      end
    end

    opts =
      opts
      |> Keyword.put(:application_startup, startup)
      |> Keyword.put(:session_id, "cancelled-startup-thread")

    task = Task.async(fn -> Tui.run(opts) end)
    assert_receive {:term_ui_started, runtime}
    assert_receive {:application_startup_waiting, startup_pid}

    send_event(event_queue, TermUI.Event.paste("cancel during startup"))
    send_event(event_queue, TermUI.Event.key(:enter))
    assert await_frame("prompt queued")
    send_event(event_queue, TermUI.Event.key("c", modifiers: [:ctrl]))
    assert await_frame("prompt cancelled")

    send(startup_pid, :continue_startup)
    assert await_frame("INPUT · Enter send")
    refute_receive {:provider_started, "cancelled-startup-thread", _request_id, _bridge}, 100

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
    frame = await_frame("STARTUP FAILED")
    assert frame =~ "STARTUP FAILED"
    send_event(event_queue, TermUI.Event.key(:escape))
    assert {:error, {:process_register_failed, :busy}} = Task.await(task, 2_000)
    assert_receive :terminal_closed
  end

  test "rejects a display policy that fails canonical catalog validation", %{
    opts: opts,
    event_queue: event_queue
  } do
    incomplete_policy = [%{identity: "openai:gpt-4.1-mini", tier: :supported}]

    opts =
      opts
      |> Keyword.put(:session_id, "invalid-catalog-thread")
      |> Keyword.put(:model_policy, incomplete_policy)

    task = Task.async(fn -> Tui.run(opts) end)
    assert_receive {:term_ui_started, _runtime}
    assert await_frame("STARTUP FAILED") =~ "Jido could not use this configuration."

    send_event(event_queue, TermUI.Event.key(:escape))

    assert {:error, {:session_attach_failed, %Jido.Console.Error.ConfigurationError{details: details}}} =
             Task.await(task, 2_000)

    assert details.reason =~ "invalid_model_policy_field"
    assert_receive :terminal_closed
  end

  test "shows a clear storage startup failure and waits for explicit exit", %{
    opts: opts,
    event_queue: event_queue
  } do
    database = "/private/jido/state/console.sqlite3"
    backup = database <> ".schema-1-backup"

    reason =
      {:jido_console,
       {{:shutdown,
         {:failed_to_start_child, Jido.Console.Storage.Supervisor,
          {:shutdown,
           {:failed_to_start_child, Jido.Console.Storage.SQLite, {:storage_schema_backup_exists, database, backup}}}}},
        {Jido.Console.Application, :start, [:normal, []]}}}

    opts =
      opts
      |> Keyword.put(:application_startup, fn -> {:error, reason} end)
      |> Keyword.put(:term_ui_backend_opts,
        test_pid: self(),
        event_queue: event_queue,
        size: {16, 120}
      )

    task = Task.async(fn -> Tui.run(opts) end)
    assert_receive {:term_ui_started, _runtime}
    frame = await_frame("STARTUP FAILED")
    assert frame =~ "STARTUP FAILED"
    assert frame =~ "An old Jido database backup already exists"
    send_event(event_queue, TermUI.Event.key(:escape))
    assert {:error, ^reason} = Task.await(task, 2_000)
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

  defp await_frame(expected, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_frame_until(expected, deadline, "")
  end

  defp await_frame_until(expected, deadline, latest) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:frame, frame} ->
        if String.contains?(frame, expected),
          do: frame,
          else: await_frame_until(expected, deadline, frame)
    after
      remaining -> flunk("frame did not contain #{inspect(expected)}; latest frame: #{inspect(latest)}")
    end
  end

  defp await_matching_frame(predicate, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_matching_frame_until(predicate, deadline, "")
  end

  defp await_matching_frame_until(predicate, deadline, latest) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:frame, frame} ->
        if predicate.(frame),
          do: frame,
          else: await_matching_frame_until(predicate, deadline, frame)
    after
      remaining -> flunk("no frame matched before timeout; latest frame: #{inspect(latest)}")
    end
  end

  defp ensure_tui_stopped(runtime, task) do
    if Process.alive?(task.pid) do
      TermUI.Runtime.shutdown(runtime)
      ref = Process.monitor(task.pid)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        2_000 ->
          Process.demonitor(ref, [:flush])
          Process.unlink(task.pid)
          Process.exit(task.pid, :kill)
      end
    end
  end

  defp await_attachment(registry, thread_id, previous \\ nil) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_await_attachment(registry, thread_id, previous, deadline)
  end

  defp do_await_attachment(registry, thread_id, previous, deadline) do
    result =
      with {:ok, owner} when owner != previous <- Registry.lookup(thread_id, registry),
           %{subscribers: subscribers} <- :sys.get_state(owner),
           [{attachment_ref, %{pid: subscriber}}] <- Map.to_list(subscribers) do
        {:ok, {owner, attachment_ref, subscriber}}
      else
        _other -> :retry
      end

    case result do
      {:ok, attachment} ->
        attachment

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("TUI did not attach to #{thread_id}")
        else
          receive do
          after
            10 -> do_await_attachment(registry, thread_id, previous, deadline)
          end
        end
    end
  catch
    :exit, _reason ->
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("TUI did not attach to #{thread_id}")
      else
        receive do
        after
          10 -> do_await_attachment(registry, thread_id, previous, deadline)
        end
      end
  end
end
