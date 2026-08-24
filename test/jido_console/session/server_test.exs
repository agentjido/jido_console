defmodule Jido.Console.Session.ServerTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{Command, Event, Server, Supervisor, View}
  alias Jido.Console.Storage
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor
  alias Jido.Console.Test.{ThreadBridge, ThreadResources}

  defmodule NoResultBridge do
    def run(owner, run_ref, action) do
      Process.link(owner)
      send(owner, {:bridge_linked, self(), run_ref})

      receive do
        {:begin, ^run_ref} -> send(action.runtime_opts[:test_pid], {:provider_started_without_result, self()})
      end
    end
  end

  defmodule FailingStore do
    @behaviour Jidoka.Session.Store

    def put_session(_session, _opts), do: {:error, :store_failed}
    def get_session(_session_id, _opts), do: {:error, :store_failed}
    def list_sessions(_opts), do: {:ok, []}
  end

  setup do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "jido-thread-owner-#{suffix}")
    writer = unique(:writer, suffix)
    storage_supervisor = unique(:storage_supervisor, suffix)
    lock = unique(:lock, suffix)
    registry = unique(:registry, suffix)
    sessions = unique(:sessions, suffix)
    tasks = unique(:tasks, suffix)
    session_supervisor = unique(:session_supervisor, suffix)

    {:ok, storage_pid} =
      StorageSupervisor.start_link(
        name: storage_supervisor,
        writer: writer,
        lock: lock,
        jido_home: root
      )

    {:ok, session_pid} =
      Supervisor.start_link(
        name: session_supervisor,
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
      if Process.alive?(session_pid), do: Process.exit(session_pid, :shutdown)
      if Process.alive?(storage_pid), do: Process.exit(storage_pid, :shutdown)
      File.rm_rf(root)
    end)

    %{opts: opts, registry: registry, sessions: sessions, tasks: tasks, storage_pid: storage_pid}
  end

  test "open and attach do not prepare execution resources", %{opts: opts} do
    {:ok, owner} = Server.ensure_started("thread-attach", opts)
    assert {:ok, %{attachment_ref: attachment_ref, view: %View{} = view}} = Server.attach(owner)
    assert is_reference(attachment_ref)
    assert view.status == :idle
    assert view.resources == %{"status" => "ready"}
    refute_received {:resources_prepared, _, _}

    assert :ok = Server.detach(owner, attachment_ref)
    assert Process.alive?(owner)
  end

  test "one active item and three pending items run in FIFO order", %{opts: opts} do
    {:ok, owner} = Server.ensure_started("thread-fifo", opts)

    commands = for index <- 1..4, do: command("thread-fifo", index)
    assert {:ok, %{status: :idle}} = Server.command(owner, hd(commands))
    assert_receive {:resources_prepared, "thread-fifo", "prompt-1"}
    assert_receive {:provider_started, "thread-fifo", "request-1", first}

    Enum.each(tl(commands), fn queued ->
      assert {:ok, %{status: :queued}} = Server.command(owner, queued)
    end)

    last =
      Enum.reduce(2..4, first, fn expected, current ->
        send(current, :finish)
        assert_receive {:provider_started, "thread-fifo", request_id, next}
        assert request_id == "request-#{expected}"
        next
      end)

    send(last, :finish)

    assert_eventually(fn -> Server.view(owner).status == :idle end)
    view = Server.view(owner)

    assert Enum.map(view.history, & &1["type"]) == [
             "prompt_queued",
             "prompt_started",
             "prompt_queued",
             "prompt_queued",
             "prompt_queued",
             "prompt_failed",
             "prompt_started",
             "prompt_failed",
             "prompt_started",
             "prompt_failed",
             "prompt_started",
             "prompt_failed"
           ]
  end

  test "provider work starts only after the durable started event", %{opts: opts} do
    {:ok, owner} = Server.ensure_started("thread-start-order", opts)
    assert {:ok, _accepted} = Server.command(owner, command("thread-start-order", 1))
    assert_receive {:provider_started, "thread-start-order", "request-1", bridge}

    assert Enum.map(Server.view(owner).history, & &1["type"]) == ["prompt_queued", "prompt_started"]
    send(bridge, :finish)
  end

  test "same-command retry has one durable item and one provider call", %{opts: opts} do
    {:ok, owner} = Server.ensure_started("thread-retry", opts)
    command = command("thread-retry", 1)

    assert {:ok, %{duplicate: false}} = Server.command(owner, command)
    assert {:ok, %{duplicate: true}} = Server.command(owner, command)
    assert_receive {:provider_started, "thread-retry", "request-1", bridge}
    refute_receive {:provider_started, "thread-retry", "request-1", _other}, 50

    conflict = %{command | text: "changed"}
    assert {:error, :command_conflict} = Server.command(owner, conflict)
    send(bridge, :finish)
  end

  test "same-command retry after terminal closure reads durable identity", %{opts: opts} do
    thread_id = "thread-closed-retry"
    {:ok, owner} = Server.ensure_started(thread_id, opts)
    command = command(thread_id, 1)

    assert {:ok, %{duplicate: false}} = Server.command(owner, command)
    assert_receive {:provider_started, ^thread_id, "request-1", bridge}
    send(bridge, :finish)
    assert_eventually(fn -> Server.view(owner).status == :idle end)

    assert {:ok, %{duplicate: true, status: :closed}} = Server.command(owner, command)
    assert {:error, :command_conflict} = Server.command(owner, %{command | text: "changed after close"})
    refute_receive {:provider_started, ^thread_id, "request-1", _other}, 50
  end

  test "a full queue checks durable history before returning queue_full", %{opts: opts} do
    opts = Keyword.put(opts, :queue_limit, 1)
    thread_id = "thread-full"
    {:ok, owner} = Server.ensure_started(thread_id, opts)

    assert {:ok, _accepted} = Server.command(owner, command(thread_id, 1))
    assert_receive {:provider_started, ^thread_id, "request-1", bridge}
    assert {:ok, %{status: :queued}} = Server.command(owner, command(thread_id, 2))
    assert {:error, :queue_full} = Server.command(owner, command(thread_id, 3))
    send(bridge, :finish)
  end

  test "reconciliation storage failures make the owner unavailable or stop it", %{opts: opts} do
    {:ok, command_owner} = Server.ensure_started("thread-reconcile-command", opts)

    :sys.replace_state(command_owner, fn state ->
      %{state | status: :reconciling, store: {FailingStore, []}}
    end)

    status = Command.new!(id: "status", type: :status, thread_id: "thread-reconcile-command")
    assert {:error, :store_failed} = Server.command(command_owner, status)
    assert Server.view(command_owner).status == :unavailable

    {:ok, wake_owner} = Server.ensure_started("thread-reconcile-wake", opts)
    monitor = Process.monitor(wake_owner)

    :sys.replace_state(wake_owner, fn state ->
      %{state | status: :reconciling, store: {FailingStore, []}}
    end)

    send(wake_owner, :reconcile)

    assert_receive {:DOWN, ^monitor, :process, ^wake_owner, {:reconciliation_failed, :store_failed}}
  end

  test "two threads can use the same queue item and request IDs", %{opts: opts} do
    first_thread = "thread-shared-identity-1"
    second_thread = "thread-shared-identity-2"
    {:ok, first_owner} = Server.ensure_started(first_thread, opts)
    {:ok, second_owner} = Server.ensure_started(second_thread, opts)

    assert {:ok, %{duplicate: false}} = Server.command(first_owner, command(first_thread, 1))
    assert {:ok, %{duplicate: false}} = Server.command(second_owner, command(second_thread, 1))
    assert_receive {:provider_started, ^first_thread, "request-1", first_bridge}
    assert_receive {:provider_started, ^second_thread, "request-1", second_bridge}

    first_ids = Enum.map(Server.view(first_owner).history, & &1["id"])
    second_ids = Enum.map(Server.view(second_owner).history, & &1["id"])
    assert MapSet.disjoint?(MapSet.new(first_ids), MapSet.new(second_ids))

    send(first_bridge, :finish)
    send(second_bridge, :finish)
  end

  test "status, history, remove, stale controls, and stale messages are deterministic", %{opts: opts} do
    thread_id = "thread-controls"
    {:ok, owner} = Server.ensure_started(thread_id, opts)
    first = command(thread_id, 1)
    second = command(thread_id, 2)

    assert {:ok, _} = Server.command(owner, first)
    assert_receive {:provider_started, ^thread_id, "request-1", bridge}
    assert {:ok, %{status: :queued}} = Server.command(owner, second)

    remove = Command.new!(id: "remove", type: :remove, thread_id: thread_id, queue_item_id: "command-2")
    assert {:ok, :removed} = Server.command(owner, remove)
    assert {:error, :thread_busy} = Server.stop(owner)

    stale_cancel = Command.new!(id: "cancel", type: :cancel, thread_id: thread_id, request_id: "stale")
    assert {:error, :stale_request} = Server.command(owner, stale_cancel)

    stale_review =
      Command.new!(id: "approve", type: :approve, thread_id: thread_id, request_id: "request-1", review_id: "stale")

    assert {:error, :review_not_pending} = Server.command(owner, stale_review)

    cross_thread = Command.new!(id: "status", type: :status, thread_id: "other")
    assert {:error, :cross_thread_command} = Server.command(owner, cross_thread)

    history = Command.new!(id: "history", type: :history, thread_id: thread_id, payload: %{limit: 10})
    assert {:ok, %{events: events}} = Server.command(owner, history)
    assert Enum.any?(events, &(&1.type == "prompt_removed"))

    send(owner, :start_active)
    send(owner, {:bridge_linked, self(), make_ref()})
    send(owner, {:bridge_handle, self(), make_ref(), "stale", :handle})
    send(owner, {:bridge_result, self(), make_ref(), "stale", :invalid})
    send(owner, :unknown_message)
    send(bridge, :finish)
  end

  test "cancel before a fake bridge handle is retained once", %{opts: opts} do
    thread_id = "thread-early-cancel"
    {:ok, owner} = Server.ensure_started(thread_id, opts)
    assert {:ok, _} = Server.command(owner, command(thread_id, 1))
    assert_receive {:provider_started, ^thread_id, "request-1", bridge}

    cancel = Command.new!(id: "cancel", type: :cancel, thread_id: thread_id, request_id: "request-1")
    assert {:ok, :requested} = Server.command(owner, cancel)
    assert {:ok, :requested} = Server.command(owner, cancel)
    send(bridge, :finish)
  end

  test "a normal bridge exit without a result stops the owner", %{opts: opts} do
    opts = Keyword.put(opts, :bridge_module, NoResultBridge)
    {:ok, owner} = Server.ensure_started("thread-missing-result", opts)
    monitor = Process.monitor(owner)
    assert {:ok, _} = Server.command(owner, command("thread-missing-result", 1))
    assert_receive {:provider_started_without_result, bridge}
    assert_receive {:DOWN, ^monitor, :process, ^owner, {:bridge_result_missing, ^bridge}}
  end

  test "unexpected hibernation and invalid bridge results close as failures", %{opts: opts} do
    for {index, result_builder} <- [
          {1, fn session -> {:hibernate, session, nil} end},
          {2, fn _session -> :invalid_bridge_result end},
          {3, fn session -> {:ok, session, %{answer: "done"}} end}
        ] do
      thread_id = "thread-result-#{index}"
      {:ok, owner} = Server.ensure_started(thread_id, opts)
      assert {:ok, _} = Server.command(owner, command(thread_id, index))
      assert_receive {:provider_started, ^thread_id, request_id, bridge}
      store = Storage.session_store(writer: opts[:writer], deadline: 5_000)
      {:ok, session} = Jidoka.Session.Store.get_session(store, thread_id)
      send(bridge, {:finish, result_builder.(session)})
      assert_eventually(fn -> Server.view(owner).status == :idle end)
      assert List.last(Server.view(owner).history)["request_id"] == request_id
    end
  end

  test "resource failure creates one durable failure and starts no bridge", %{opts: opts} do
    opts = Keyword.put(opts, :fail_resources, true)
    {:ok, owner} = Server.ensure_started("thread-resource-failure", opts)

    assert {:ok, _accepted} = Server.command(owner, command("thread-resource-failure", 1))
    assert_eventually(fn -> Server.view(owner).status == :idle end)
    refute_received {:provider_started, _, _, _}
    assert Enum.map(Server.view(owner).history, & &1["type"]) == ["prompt_queued", "prompt_failed"]
  end

  test "bridge creation failure becomes one durable failed outcome", %{opts: opts} do
    opts = Keyword.put(opts, :tasks, :missing_thread_task_supervisor)
    {:ok, owner} = Server.ensure_started("thread-bridge-start-failure", opts)

    assert {:ok, _accepted} = Server.command(owner, command("thread-bridge-start-failure", 1))
    assert_eventually(fn -> Server.view(owner).status == :idle end)
    refute_received {:provider_started, _, _, _}
    assert Enum.map(Server.view(owner).history, & &1["type"]) == ["prompt_queued", "prompt_failed"]
  end

  test "a start-event write failure does not begin provider work", %{opts: opts, storage_pid: storage_pid} do
    {:ok, owner} = Server.ensure_started("thread-start-write-failure", opts)
    held = %{command("thread-start-write-failure", 1) | text: "hold-link"}
    assert {:ok, _accepted} = Server.command(owner, held)
    assert_receive {:bridge_waiting_to_link, bridge}

    monitor = Process.monitor(storage_pid)
    Process.unlink(storage_pid)
    Process.exit(storage_pid, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^storage_pid, :shutdown}
    send(bridge, :link_now)

    assert_eventually(fn -> Server.view(owner).status == :unavailable end)
    refute_received {:provider_started, _, _, _}
    assert Enum.map(Server.view(owner).history, & &1["type"]) == ["prompt_queued"]
  end

  test "an attach survives setup failure and a later prompt retries setup", %{opts: opts} do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    opts = Keyword.put(opts, :fail_resources_once, attempts)
    {:ok, owner} = Server.ensure_started("thread-resource-retry", opts)

    assert {:ok, %{view: %View{status: :idle}}} = Server.attach(owner)
    assert {:ok, _accepted} = Server.command(owner, command("thread-resource-retry", 1))
    assert_eventually(fn -> Server.view(owner).status == :idle end)
    refute_received {:provider_started, _, "request-1", _}

    assert {:ok, _accepted} = Server.command(owner, command("thread-resource-retry", 2))
    assert_receive {:resources_prepared, "thread-resource-retry", "prompt-2"}
    assert_receive {:provider_started, "thread-resource-retry", "request-2", bridge}
    send(bridge, :finish)
  end

  test "an abnormal bridge exit leaves a temporary gap and replacement interrupts old work", %{opts: opts} do
    thread_id = "thread-crash"
    {:ok, owner} = Server.ensure_started(thread_id, opts)
    monitor = Process.monitor(owner)

    assert {:ok, _accepted} = Server.command(owner, %{command(thread_id, 1) | text: "crash"})
    assert_receive {:provider_started, ^thread_id, "request-1", _bridge}
    assert_receive {:DOWN, ^monitor, :process, ^owner, {:bridge_exit, :provider_crash}}
    assert {:error, :not_found} = Jido.Console.Session.Registry.lookup(thread_id, opts[:registry])

    {:ok, replacement} = Server.ensure_started(thread_id, opts)
    refute replacement == owner
    assert Server.view(replacement).status == :idle

    assert Enum.map(Server.view(replacement).history, & &1["type"]) ==
             ["prompt_queued", "prompt_started", "prompt_interrupted"]
  end

  test "attach returns revision N and receives only later complete views", %{opts: opts} do
    {:ok, owner} = Server.ensure_started("thread-view", opts)
    assert {:ok, %{attachment_ref: attachment_ref, view: first}} = Server.attach(owner)
    assert first.revision == 0

    assert {:ok, _accepted} = Server.command(owner, command("thread-view", 1))
    assert_receive {:jido_console_view, ^attachment_ref, %View{revision: revision} = later}
    assert revision > first.revision
    assert later.active["request_id"] == "request-1"
  end

  test "terminal transition flushes one ordered partial view before clearing it", %{opts: opts} do
    thread_id = "thread-partial-flush"
    opts = Keyword.put(opts, :partial_publish_interval_ms, 1_000)
    {:ok, owner} = Server.ensure_started(thread_id, opts)
    assert {:ok, _accepted} = Server.command(owner, command(thread_id, 1))
    assert_receive {:provider_started, ^thread_id, "request-1", bridge}
    assert {:ok, %{attachment_ref: attachment_ref}} = Server.attach(owner)

    for sequence <- 1..3 do
      send(
        bridge,
        {:emit,
         Jidoka.Event.build(:llm_delta, [],
           request_id: "request-1",
           seq: sequence,
           data: %{text: Integer.to_string(sequence)}
         )}
      )
    end

    send(bridge, :finish)

    assert_receive {:jido_console_view, ^attachment_ref, %View{status: :running} = partial}
    assert Enum.map(partial.partial, & &1.seq) == [1, 2, 3]
    assert_receive {:jido_console_view, ^attachment_ref, %View{status: :idle, partial: []}}
    refute_receive {:jido_console_view, ^attachment_ref, _view}, 50
  end

  test "real Jidoka cancellation closes the active item before the next FIFO item", %{opts: opts} do
    test_pid = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    llm = fn _intent, _journal, _context ->
      call = Agent.get_and_update(calls, fn count -> {count, count + 1} end)
      send(test_pid, {:real_llm_call, call, self()})

      if call == 0 do
        receive do
          :release_cancelled_call -> {:ok, %{type: :final, content: "late"}}
        end
      else
        {:ok, %{type: :final, content: "second completed"}}
      end
    end

    opts = real_jidoka_opts(opts, llm: llm)
    {:ok, owner} = Server.ensure_started("thread-cancel", opts)
    assert {:ok, _} = Server.command(owner, command("thread-cancel", 1))
    assert_receive {:real_llm_call, 0, _llm_pid}
    assert {:ok, %{status: :queued}} = Server.command(owner, command("thread-cancel", 2))

    cancel =
      Command.new!(
        id: "cancel-1",
        type: :cancel,
        thread_id: "thread-cancel",
        request_id: "request-1"
      )

    assert {:ok, :requested} = Server.command(owner, cancel)
    assert_receive {:real_llm_call, 1, _second_llm}
    assert_eventually(fn -> Server.view(owner).status == :idle end)

    history = Server.view(owner).history

    assert Enum.map(history, & &1["type"]) == [
             "prompt_queued",
             "prompt_started",
             "prompt_queued",
             "prompt_cancelled",
             "prompt_started",
             "prompt_succeeded"
           ]
  end

  test "review pauses the FIFO and approval continues with a fresh fenced bridge", %{opts: opts} do
    test_pid = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    llm = fn _intent, _journal, _context ->
      case rem(Agent.get_and_update(calls, fn count -> {count, count + 1} end), 2) do
        0 -> {:ok, %{type: :operation, name: "review_lookup", arguments: %{"id" => "reviewed"}}}
        1 -> {:ok, %{type: :final, content: "review approved"}}
      end
    end

    operations = review_capability(test_pid)

    spec =
      Jidoka.Agent.Spec.new!(
        id: "review-agent",
        instructions: "Use review_lookup before the final answer.",
        model: "openai:gpt-4.1-mini",
        operations: [
          Jidoka.Agent.Spec.Operation.new!(
            name: "review_lookup",
            idempotency: :idempotent,
            approval: %{required: true, reason: "test review"}
          )
        ],
        runtime_defaults: %{max_model_turns: 4}
      )

    opts = real_jidoka_opts(opts, agent: spec, llm: llm, operations: operations)
    {:ok, owner} = Server.ensure_started("thread-review", opts)
    assert {:ok, _} = Server.command(owner, command("thread-review", 1))
    assert_eventually(fn -> Server.view(owner).status == :review end)

    review_view = Server.view(owner)
    review_id = review_view.review["id"]
    assert is_binary(review_id)

    cancel =
      Command.new!(id: "cancel-review", type: :cancel, thread_id: "thread-review", request_id: "request-1")

    assert {:error, :review_pending} = Server.command(owner, cancel)
    revision = review_view.revision

    send(
      owner,
      {:bridge_event, make_ref(), "request-1",
       Jidoka.Event.build(:llm_delta, [text: "stale"], request_id: "request-1", seq: 99)}
    )

    assert Server.view(owner).revision == revision

    approve =
      Command.new!(
        id: "approve-review",
        type: :approve,
        thread_id: "thread-review",
        request_id: "request-1",
        review_id: review_id
      )

    stale_approve = %{approve | review_id: "stale-review"}
    assert {:error, :stale_review} = Server.command(owner, stale_approve)

    assert {:ok, :requested} = Server.command(owner, approve)
    assert_eventually(fn -> Server.view(owner).status == :idle end)
    history = Server.view(owner).history

    assert Enum.map(history, & &1["type"]) == [
             "prompt_queued",
             "prompt_started",
             "review_presented",
             "prompt_succeeded"
           ]

    assert_received {:review_lookup_called, "reviewed"}

    assert {:ok, _} = Server.command(owner, command("thread-review", 2))
    assert_eventually(fn -> Server.view(owner).status == :review end)
    denied_review_id = Server.view(owner).review["id"]

    deny =
      Command.new!(
        id: "deny-review",
        type: :deny,
        thread_id: "thread-review",
        request_id: "request-2",
        review_id: denied_review_id
      )

    assert {:ok, :requested} = Server.command(owner, deny)
    assert_eventually(fn -> Server.view(owner).status == :idle end)
    refute_receive {:review_lookup_called, "reviewed"}, 50
    assert List.last(Server.view(owner).history)["type"] == "prompt_failed"
  end

  test "one prompt can present two distinct durable reviews", %{opts: opts} do
    test_pid = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    llm = fn _intent, _journal, _context ->
      case Agent.get_and_update(calls, fn count -> {count, count + 1} end) do
        0 -> {:ok, %{type: :operation, name: "review_lookup", arguments: %{"id" => "first"}}}
        1 -> {:ok, %{type: :operation, name: "review_lookup", arguments: %{"id" => "second"}}}
        _count -> {:ok, %{type: :final, content: "both approved"}}
      end
    end

    spec = review_spec(6)
    opts = real_jidoka_opts(opts, agent: spec, llm: llm, operations: review_capability(test_pid))
    thread_id = "thread-two-reviews"
    {:ok, owner} = Server.ensure_started(thread_id, opts)
    assert {:ok, _} = Server.command(owner, command(thread_id, 1))
    assert_eventually(fn -> Server.view(owner).status == :review end)
    first_review_id = Server.view(owner).review["id"]

    assert {:ok, :requested} = Server.command(owner, approval(thread_id, first_review_id, 1))

    assert_eventually(fn ->
      view = Server.view(owner)
      view.status == :review and view.review["id"] != first_review_id
    end)

    second_review_id = Server.view(owner).review["id"]
    reviews = Enum.filter(Server.view(owner).history, &(&1["type"] == "review_presented"))
    assert Enum.map(reviews, & &1["payload"]["review"]["id"]) == [first_review_id, second_review_id]
    assert Enum.uniq(Enum.map(reviews, & &1["id"])) == Enum.map(reviews, & &1["id"])

    assert {:ok, :requested} = Server.command(owner, approval(thread_id, second_review_id, 2))
    assert_eventually(fn -> Server.view(owner).status == :idle end)
    assert_received {:review_lookup_called, "first"}
    assert_received {:review_lookup_called, "second"}
  end

  test "a live lease blocks replacement work and a committed terminal state wins", %{opts: opts} do
    thread_id = "thread-live-recovery"
    store = Storage.session_store(writer: opts[:writer], deadline: 5_000)
    _session = seed_open_thread(thread_id, opts)
    request = Jidoka.Turn.Request.new!(input: "old work", request_id: "old-request")

    assert {:ok, claimed} =
             Jidoka.Session.Store.claim_session(store, thread_id, request,
               clock: fn -> 100 end,
               lease_ttl_ms: 100,
               owner_id: "old-owner"
             )

    owner_opts = Keyword.put(opts, :clock, fn -> 150 end)
    {:ok, owner} = Server.ensure_started(thread_id, owner_opts)
    assert Server.view(owner).status == :reconciling
    assert {:error, :thread_reconciling} = Server.stop(owner)
    send(owner, :reconcile)
    assert_eventually(fn -> Server.view(owner).status == :reconciling end)
    assert {:error, :thread_reconciling} = Server.command(owner, command(thread_id, 2))

    interrupted = Jidoka.Session.Data.put_error(claimed, :provider_failed)

    assert {:ok, _terminal} =
             Jidoka.Session.Store.commit_session(store, thread_id, claimed.lease.lease_id, interrupted,
               clock: fn -> 160 end
             )

    status = Command.new!(id: "status-live", type: :status, thread_id: thread_id)
    assert {:ok, %View{status: :idle}} = Server.command(owner, status)

    assert Enum.map(Server.view(owner).history, & &1["type"]) ==
             ["prompt_queued", "prompt_started", "prompt_failed"]
  end

  test "an expired lease is interrupted and no old prompt resumes", %{opts: opts} do
    thread_id = "thread-expired-recovery"
    store = Storage.session_store(writer: opts[:writer], deadline: 5_000)
    _session = seed_open_thread(thread_id, opts)
    request = Jidoka.Turn.Request.new!(input: "old work", request_id: "old-request")

    assert {:ok, claimed} =
             Jidoka.Session.Store.claim_session(store, thread_id, request,
               clock: fn -> 100 end,
               lease_ttl_ms: 10,
               owner_id: "old-owner"
             )

    {:ok, owner} = Server.ensure_started(thread_id, Keyword.put(opts, :clock, fn -> 110 end))
    assert Server.view(owner).status == :idle
    refute_received {:provider_started, _, _, _}

    assert Enum.map(Server.view(owner).history, & &1["type"]) ==
             ["prompt_queued", "prompt_started", "prompt_interrupted"]

    assert {:error, {:stale_session_lease, ^thread_id, _lease_id}} =
             Jidoka.Session.Store.commit_session(
               store,
               thread_id,
               claimed.lease.lease_id,
               Jidoka.Session.Data.put_error(claimed, :late),
               clock: fn -> 111 end
             )
  end

  test "recovery projects durable success and cancellation outcomes", %{opts: opts} do
    for {suffix, finish, event_type} <- [
          {"success", &successful_session/1, "prompt_succeeded"},
          {"cancelled", &Jidoka.Session.Data.put_cancellation(&1, :cancelled_by_user), "prompt_cancelled"}
        ] do
      thread_id = "thread-terminal-#{suffix}"
      _session = seed_open_thread(thread_id, opts)
      store = Storage.session_store(writer: opts[:writer], deadline: 5_000)
      request = Jidoka.Turn.Request.new!(input: "old work", request_id: "old-request")

      assert {:ok, claimed} =
               Jidoka.Session.Store.claim_session(store, thread_id, request,
                 clock: fn -> 100 end,
                 lease_ttl_ms: 10,
                 owner_id: "terminal-owner"
               )

      terminal = finish.(claimed)

      assert {:ok, _} =
               Jidoka.Session.Store.commit_session(store, thread_id, claimed.lease.lease_id, terminal,
                 clock: fn -> 101 end
               )

      assert {:ok, owner} = Server.ensure_started(thread_id, opts)
      assert Server.view(owner).status == :idle
      assert List.last(Server.view(owner).history)["type"] == event_type
    end
  end

  test "replacement interrupts every open FIFO item once and does not restart old work", %{opts: opts} do
    thread_id = "thread-multi-interrupt"
    seed_open_items(thread_id, 3, opts)
    store = Storage.session_store(writer: opts[:writer], deadline: 5_000)
    request = Jidoka.Turn.Request.new!(input: "old work 1", request_id: "old-request-1")

    assert {:ok, _claimed} =
             Jidoka.Session.Store.claim_session(store, thread_id, request,
               clock: fn -> 100 end,
               lease_ttl_ms: 10,
               owner_id: "old-owner"
             )

    {:ok, owner} = Server.ensure_started(thread_id, Keyword.put(opts, :clock, fn -> 110 end))
    assert Server.view(owner).status == :idle
    assert_closes_open_items_once(owner, "prompt_interrupted", 3)
    refute_received {:provider_started, ^thread_id, _, _}

    assert :ok = Server.stop(owner)
    {:ok, replacement} = Server.ensure_started(thread_id, opts)
    assert_closes_open_items_once(replacement, "prompt_interrupted", 3)
    refute_received {:provider_started, ^thread_id, _, _}
  end

  test "replacement interrupts a queued-only first prompt and does not restart it", %{opts: opts} do
    thread_id = "thread-queued-only-replacement"
    seed_open_items(thread_id, 1, opts, false)

    assert {:ok, owner} = Server.ensure_started(thread_id, opts)
    assert Server.view(owner).status == :idle

    assert Enum.map(Server.view(owner).history, & &1["type"]) ==
             ["prompt_queued", "prompt_interrupted"]

    refute_received {:provider_started, ^thread_id, _, _}
  end

  test "legacy history blocks binding adoption without changing the stored event", %{opts: opts} do
    thread_id = "thread-legacy-history"
    spec = Jido.Console.Agents.Default.spec()
    assert {:ok, session} = Jidoka.Session.Data.start(spec, session_id: thread_id)
    store = Storage.session_store(writer: opts[:writer], deadline: 5_000)
    assert {:ok, ^session} = Jidoka.Session.Store.put_session(store, session)

    event =
      Event.new!(
        id: Event.event_id(thread_id, "legacy-item", "prompt_queued"),
        type: "prompt_queued",
        session_id: thread_id,
        queue_item_id: "legacy-item",
        request_id: "legacy-request",
        payload: %{
          "input" => "old prompt",
          "context" => %{},
          "command_digest" => "legacy-command"
        }
      )

    assert {:ok, %{event: stored}} =
             Storage.append_thread_event(event, writer: opts[:writer], deadline: 5_000)

    assert {:ok, owner} = Server.ensure_started(thread_id, opts)
    view = Server.view(owner)
    assert view.binding_state == :resume_blocked
    assert Enum.map(view.history, & &1["id"]) == [stored.id]

    assert {:ok, unchanged} = Jidoka.Session.Store.get_session(store, thread_id)
    assert unchanged == session
    refute_received {:provider_started, ^thread_id, _, _}
  end

  test "replacement keeps one durable terminal and interrupts queued FIFO items once", %{opts: opts} do
    thread_id = "thread-multi-terminal"
    seed_open_items(thread_id, 3, opts)
    store = Storage.session_store(writer: opts[:writer], deadline: 5_000)
    request = Jidoka.Turn.Request.new!(input: "old work 1", request_id: "old-request-1")

    assert {:ok, claimed} =
             Jidoka.Session.Store.claim_session(store, thread_id, request,
               clock: fn -> 100 end,
               lease_ttl_ms: 10,
               owner_id: "old-owner"
             )

    assert {:ok, _terminal} =
             Jidoka.Session.Store.commit_session(
               store,
               thread_id,
               claimed.lease.lease_id,
               successful_session(claimed, "old-request-1"),
               clock: fn -> 101 end
             )

    {:ok, owner} = Server.ensure_started(thread_id, opts)
    closing = Enum.filter(Server.view(owner).history, &Event.closing?(&1["type"]))
    assert Enum.map(closing, & &1["type"]) == ["prompt_succeeded", "prompt_interrupted", "prompt_interrupted"]

    assert Enum.frequencies_by(closing, & &1["queue_item_id"]) == %{
             "#{thread_id}-old-item-1" => 1,
             "#{thread_id}-old-item-2" => 1,
             "#{thread_id}-old-item-3" => 1
           }

    refute_received {:provider_started, ^thread_id, _, _}
  end

  test "recovery rejects a running lease with a different product request", %{opts: opts} do
    thread_id = "thread-recovery-mismatch"
    _session = seed_open_thread(thread_id, opts)
    store = Storage.session_store(writer: opts[:writer], deadline: 5_000)
    request = Jidoka.Turn.Request.new!(input: "other work", request_id: "other-request")

    assert {:ok, _claimed} =
             Jidoka.Session.Store.claim_session(store, thread_id, request,
               clock: fn -> 100 end,
               lease_ttl_ms: 100,
               owner_id: "other-owner"
             )

    assert {:error, {:recovery_request_mismatch, "old-request", "other-request"}} =
             Server.ensure_started(thread_id, Keyword.put(opts, :clock, fn -> 110 end))
  end

  defp command(thread_id, index) do
    Command.new!(
      id: "command-#{index}",
      type: :submit,
      thread_id: thread_id,
      queue_item_id: "command-#{index}",
      request_id: "request-#{index}",
      text: "prompt-#{index}",
      payload: %{"context" => %{}}
    )
  end

  defp approval(thread_id, review_id, index) do
    Command.new!(
      id: "approve-review-#{index}",
      type: :approve,
      thread_id: thread_id,
      request_id: "request-1",
      review_id: review_id
    )
  end

  defp unique(label, suffix), do: String.to_atom("#{label}-#{suffix}")

  defp real_jidoka_opts(opts, runtime_opts) do
    opts
    |> Keyword.delete(:resources_module)
    |> Keyword.delete(:bridge_module)
    |> Keyword.delete(:test_pid)
    |> Keyword.put(:coding_pack, :disabled)
    |> Keyword.put(:turn_opts, Keyword.take(runtime_opts, [:llm]))
    |> Keyword.merge(Keyword.take(runtime_opts, [:agent, :operations]))
  end

  defp review_capability(test_pid) do
    source =
      Jidoka.Operation.Source.Local.new!(
        operations: [
          %{
            name: "review_lookup",
            handler: fn %{"id" => id}, _context ->
              send(test_pid, {:review_lookup_called, id})
              {:ok, %{id: id}}
            end
          }
        ]
      )

    {:ok, compiled} = Jidoka.Operation.Source.compile(source)
    compiled.capability
  end

  defp review_spec(max_model_turns) do
    Jidoka.Agent.Spec.new!(
      id: "review-agent",
      instructions: "Use review_lookup before the final answer.",
      model: "openai:gpt-4.1-mini",
      operations: [
        Jidoka.Agent.Spec.Operation.new!(
          name: "review_lookup",
          idempotency: :idempotent,
          approval: %{required: true, reason: "test review"}
        )
      ],
      runtime_defaults: %{max_model_turns: max_model_turns}
    )
  end

  defp seed_open_thread(thread_id, opts) do
    seed_open_items(thread_id, 1, opts)
  end

  defp seed_open_items(thread_id, count, opts, started? \\ true) do
    {:ok, selection} = Jido.Console.Session.Selection.new(thread_id: thread_id)
    {:ok, session} = Jido.Console.Session.Selection.start_session(selection, thread_id)
    store = Storage.session_store(writer: opts[:writer], deadline: 5_000)
    assert {:ok, ^session} = Jidoka.Session.Store.put_session(store, session)

    for index <- 1..count do
      item_id = if(count == 1, do: "#{thread_id}-old-item", else: "#{thread_id}-old-item-#{index}")
      request_id = if(count == 1, do: "old-request", else: "old-request-#{index}")

      if index == 1 do
        command =
          Command.new!(
            id: item_id,
            type: :submit,
            thread_id: thread_id,
            queue_item_id: item_id,
            request_id: request_id,
            text: "old work #{index}",
            payload: %{"context" => %{}}
          )

        operation_id = Command.lock_operation_id(command)

        first_digest =
          Command.first_lock_digest(command, selection.manifest["binding_digest"])

        {:ok, locked} =
          Jido.Console.Session.Selection.lock(selection, operation_id, first_digest)

        {:ok, locked_session} =
          Jido.Console.Session.BindingManifest.put(
            %{session | revision: session.revision + 1},
            locked.manifest
          )

        queued =
          Event.new!(
            id: Event.event_id(thread_id, item_id, "prompt_queued"),
            type: "prompt_queued",
            session_id: thread_id,
            queue_item_id: item_id,
            request_id: request_id,
            jidoka_revision: locked_session.revision,
            payload: %{
              "input" => command.text,
              "context" => %{},
              "command_digest" => Command.digest(command),
              "binding_digest" => locked.manifest["binding_digest"],
              "lock_operation_id" => operation_id,
              "first_prompt_command_digest" => first_digest
            }
          )

        assert {:ok, %{session: _committed}} =
                 Storage.lock_first_prompt(
                   locked_session,
                   queued,
                   operation_id,
                   session.revision,
                   selection.generation,
                   writer: opts[:writer],
                   deadline: 5_000
                 )

        if started? do
          started =
            Event.new!(
              id: Event.event_id(thread_id, item_id, "prompt_started"),
              type: "prompt_started",
              session_id: thread_id,
              queue_item_id: item_id,
              request_id: request_id,
              payload: %{}
            )

          assert {:ok, _stored} =
                   Storage.append_thread_event(started, writer: opts[:writer], deadline: 5_000)
        end

        Process.put({__MODULE__, thread_id, :selection}, locked)
      else
        locked = Process.get({__MODULE__, thread_id, :selection})

        queued =
          Event.new!(
            id: Event.event_id(thread_id, item_id, "prompt_queued"),
            type: "prompt_queued",
            session_id: thread_id,
            queue_item_id: item_id,
            request_id: request_id,
            payload: %{
              "input" => "old work #{index}",
              "context" => %{},
              "command_digest" => "old-#{index}",
              "binding_digest" => locked.manifest["binding_digest"]
            }
          )

        assert {:ok, _stored} =
                 Storage.append_thread_event(queued, writer: opts[:writer], deadline: 5_000)
      end
    end

    Process.delete({__MODULE__, thread_id, :selection})
  end

  defp successful_session(session) do
    successful_session(session, "old-request")
  end

  defp successful_session(session, request_id) do
    result =
      Jidoka.Turn.Result.new!(
        content: "done",
        agent_state: session.conversation.agent_state,
        journal: Jidoka.Effect.Journal.new!(),
        metadata: %{debug: %{request_id: request_id}}
      )

    Jidoka.Session.Data.put_result(session, result)
  end

  defp assert_closes_open_items_once(owner, type, count) do
    closing = Enum.filter(Server.view(owner).history, &Event.closing?(&1["type"]))
    assert length(closing) == count
    assert Enum.all?(closing, &(&1["type"] == type))
    assert Enum.all?(closing, &String.starts_with?(&1["id"], Server.view(owner).thread_id <> ":"))
    assert Enum.all?(Enum.frequencies_by(closing, & &1["queue_item_id"]), fn {_item, frequency} -> frequency == 1 end)
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      receive do
      after
        10 -> :ok
      end

      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
