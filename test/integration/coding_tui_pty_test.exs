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
    assert_frame("INPUT · Enter send")

    send_event(event_queue, TermUI.Event.paste("/help"))
    send_event(event_queue, TermUI.Event.key(:enter))
    assert_frame("/model [provider:model]")

    send_event(event_queue, TermUI.Event.paste("/model"))
    send_event(event_queue, TermUI.Event.key(:enter))
    assert_frame("openai:gpt-4.1-mini supported current")

    send_event(event_queue, TermUI.Event.paste("/model ollama:llama3.2"))
    send_event(event_queue, TermUI.Event.key(:enter))
    assert_frame("Selected model ollama:llama3.2 (beta)", 10_000)

    send_event(event_queue, TermUI.Event.paste("Inspect this project."))
    send_event(event_queue, TermUI.Event.key(:enter))
    assert_frame("Provider-free answer.", 5_000)

    send_event(event_queue, TermUI.Event.paste("/model openai:gpt-4.1-mini"))
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

  defp unique(label, suffix), do: String.to_atom("#{label}-#{suffix}")

  defp send_event(queue, event) do
    Agent.update(queue, &:queue.in(event, &1))
  end
end
