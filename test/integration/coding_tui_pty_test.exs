defmodule Jido.Console.CodingTuiPtyTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{Client, Supervisor}
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor
  alias Jido.Console.Test.TermUIBackend
  alias Jido.Console.Tui

  setup do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "jido-coding-tui-#{suffix}")
    writer = unique(:writer, suffix)
    registry = unique(:registry, suffix)
    sessions = unique(:sessions, suffix)
    tasks = unique(:tasks, suffix)
    session_supervisor_name = unique(:session_supervisor, suffix)

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

    on_exit(fn ->
      if Process.alive?(session_supervisor), do: Process.exit(session_supervisor, :shutdown)
      if Process.alive?(storage), do: Process.exit(storage, :shutdown)
      File.rm_rf(root)
    end)

    %{root: root, writer: writer, registry: registry, sessions: sessions, tasks: tasks, name: session_supervisor_name}
  end

  test "runs a provider-free Jidoka turn and restores its durable View", context do
    thread_id = "coding-tui-thread"
    {:ok, event_queue} = Agent.start_link(fn -> :queue.new() end)
    {:ok, validated_catalog} = Jido.Console.Models.list()
    llm = fn _intent, _journal, _context -> {:ok, %{type: :final, content: "Provider-free answer."}} end

    opts = [
      name: context.name,
      registry: context.registry,
      sessions: context.sessions,
      tasks: context.tasks,
      writer: context.writer,
      jido_home: context.root,
      session_id: thread_id,
      coding_pack: :disabled,
      turn_opts: [llm: llm],
      term_ui_backend: TermUIBackend,
      term_ui_backend_opts: [test_pid: self(), event_queue: event_queue, size: {20, 80}],
      application_startup: fn -> :ok end,
      process_register: fn _kind, _pid, _opts -> {:ok, %{}} end,
      process_stop: fn _id, _opts -> :ok end,
      validated_model_catalog_entries: validated_catalog,
      catalog_entries: [
        %{
          identity: "openai:gpt-4.1-mini",
          provider: "openai",
          model: "gpt-4.1-mini",
          tier: :supported
        },
        %{identity: "ollama:llama3.2", provider: "ollama", model: "llama3.2", tier: :beta}
      ]
    ]

    task = Task.async(fn -> Tui.run(opts) end)
    assert_receive {:term_ui_started, runtime}, 2_000
    on_exit(fn -> ensure_tui_stopped(runtime, task) end)
    assert_frame("INPUT · Enter send")

    send_event(event_queue, TermUI.Event.paste("/"))
    assert_frame("> /help · Show slash commands")

    send_event(event_queue, TermUI.Event.key(:down))
    send_event(event_queue, TermUI.Event.key(:down))
    send_event(event_queue, TermUI.Event.key(:down))
    assert_frame("> /model [provider:model] · List or select a model")

    send_event(event_queue, TermUI.Event.key(:tab))

    assert_frame_matching(fn frame ->
      String.contains?(frame, "> ollama:llama3.2 · beta") and
        String.contains?(frame, "openai:gpt-4.1-mini · supported · current")
    end)

    send_event(event_queue, TermUI.Event.paste("oll"))

    filtered =
      assert_frame_matching(fn frame ->
        String.contains?(frame, "> /model oll") and
          String.contains?(frame, "> ollama:llama3.2 · beta") and
          not String.contains?(frame, "> openai:gpt-4.1-mini · supported")
      end)

    assert filtered =~ "1 result"

    send_event(event_queue, TermUI.Event.key(:tab))

    completed =
      assert_frame_matching(fn frame ->
        String.contains?(frame, "> /model ollama:llama3.2") and
          String.contains?(frame, "JIDO · openai:gpt-4.1-mini supported") and
          not String.contains?(frame, "Tab complete")
      end)

    refute completed =~ "Selected model ollama:llama3.2"
    send_event(event_queue, TermUI.Event.key(:enter))
    assert_frame("Selected model ollama:llama3.2 (beta)", 10_000)

    send_event(event_queue, TermUI.Event.paste("Inspect this project."))
    send_event(event_queue, TermUI.Event.key(:enter))
    assert_frame("Provider-free answer.", 5_000)

    send_event(event_queue, TermUI.Event.paste("/model open"))
    assert_frame("> openai:gpt-4.1-mini · supported")
    send_event(event_queue, TermUI.Event.key(:tab))
    assert_frame("> /model openai:gpt-4.1-mini")
    send_event(event_queue, TermUI.Event.key(:enter))
    assert_frame("locked after the first prompt")

    TermUI.Runtime.shutdown(runtime)
    assert :ok = Task.await(task, 2_000)
    assert_receive :terminal_closed

    assert {:ok, %{handle: handle, view: view}} = Client.attach(thread_id, opts)
    assert Enum.map(view.history, & &1["type"]) == ["prompt_queued", "prompt_started", "prompt_succeeded"]
    assert Enum.any?(view.transcript, &(Map.get(&1, :content, Map.get(&1, "content")) == "Provider-free answer."))
    assert view.model == %{"identity" => "ollama:llama3.2", "tier" => "beta", "locked" => true}
    refute inspect(view.transcript) =~ "/model"
    refute inspect(view.history) =~ "/model"
    refute Map.has_key?(view, :completion)
    assert :ok = Client.detach(handle)
    assert :ok = Client.stop(handle)
  end

  test "selects a file agent and grants its requested policy before the first prompt", context do
    thread_id = "coding-tui-selection-thread"
    source = Path.join(context.root, "trusted agent.json")
    File.cp!("test/fixtures/agents/trusted.json", source)
    {:ok, event_queue} = Agent.start_link(fn -> :queue.new() end)
    {:ok, validated_catalog} = Jido.Console.Models.list()

    opts = [
      name: context.name,
      registry: context.registry,
      sessions: context.sessions,
      tasks: context.tasks,
      writer: context.writer,
      jido_home: context.root,
      session_id: thread_id,
      project_root: context.root,
      coding_pack: :disabled,
      term_ui_backend: TermUIBackend,
      term_ui_backend_opts: [test_pid: self(), event_queue: event_queue, size: {20, 90}],
      application_startup: fn -> :ok end,
      process_register: fn _kind, _pid, _opts -> {:ok, %{}} end,
      process_stop: fn _id, _opts -> :ok end,
      validated_model_catalog_entries: validated_catalog,
      catalog_entries: [
        %{
          identity: "openai:gpt-4.1-mini",
          provider: "openai",
          model: "gpt-4.1-mini",
          tier: :supported
        }
      ]
    ]

    task = Task.async(fn -> Tui.run(opts) end)
    assert_receive {:term_ui_started, runtime}, 2_000
    on_exit(fn -> ensure_tui_stopped(runtime, task) end)
    assert_frame("Agent     jido")

    send_event(event_queue, TermUI.Event.paste("/agent #{source}"))
    send_event(event_queue, TermUI.Event.key(:enter))

    assert_frame_matching(
      fn frame ->
        String.contains?(frame, "Agent     trusted_file_agent") and
          String.contains?(frame, "Policy    coding.trusted-workspace")
      end,
      5_000
    )

    send_event(event_queue, TermUI.Event.paste("/execution-policy coding.trusted-workspace"))
    send_event(event_queue, TermUI.Event.key(:enter))

    assert_frame_matching(
      fn frame ->
        String.contains?(frame, "Selected execution policy") and
          String.contains?(frame, "coding.trusted-workspace (not a sandbox)")
      end,
      5_000
    )

    TermUI.Runtime.shutdown(runtime)
    assert :ok = Task.await(task, 2_000)
    assert_receive :terminal_closed

    assert {:ok, %{handle: handle, view: view}} = Client.attach(thread_id, opts)
    assert view.binding_state == :ready_unlocked
    assert view.binding["agent"]["id"] == "trusted_file_agent"
    assert view.binding["execution_policy"]["id"] == "coding.trusted-workspace"
    assert view.history == []
    assert :ok = Client.detach(handle)
    assert :ok = Client.stop(handle)
  end

  defp assert_frame(expected, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_frame(expected, deadline, "")
  end

  defp await_frame(expected, deadline, latest) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:frame, frame} ->
        if String.contains?(frame, expected), do: frame, else: await_frame(expected, deadline, frame)
    after
      remaining -> flunk("frame did not contain #{inspect(expected)}; latest frame: #{inspect(latest)}")
    end
  end

  defp assert_frame_matching(predicate, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_matching_frame(predicate, deadline, "")
  end

  defp await_matching_frame(predicate, deadline, latest) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:frame, frame} ->
        if predicate.(frame), do: frame, else: await_matching_frame(predicate, deadline, frame)
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

  defp unique(label, suffix), do: String.to_atom("#{label}-#{suffix}")

  defp send_event(queue, event) do
    Agent.update(queue, &:queue.in(event, &1))
  end
end
