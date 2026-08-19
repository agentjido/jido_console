defmodule Jido.Console.Session.Client.TUITest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Client, Identity, Registry, Server, Supervisor}
  alias Jido.Console.Session.Client.TUI
  alias Jido.Console.Tui.State
  alias Jido.Console.Runtime.Result
  alias Jidoka.Event

  defmodule Runtime do
    @behaviour Jido.Console.Runtime

    @impl true
    def start_session(_agent, opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def start_turn(session, _prompt, owner, _opts) do
      request = %{request_id: "detach-request", owner: owner, test_pid: session.test_pid}

      send(
        owner,
        {:jidoka_turn_event,
         Event.build(:llm_delta, [],
           request_id: request.request_id,
           seq: 0,
           data: %{chunk_type: :content, delta: "still running"}
         )}
      )

      {:ok, request}
    end

    @impl true
    def await(request, _opts) do
      send(request.test_pid, {:runtime_waiting, self()})

      receive do
        :finish ->
          send(
            request.owner,
            {:jidoka_turn_event, Event.build(:turn_finished, [], request_id: request.request_id, seq: 1)}
          )

          session = %{test_pid: request.test_pid}
          Result.ok(request.request_id, session, request, "still running")
      end
    end

    @impl true
    def cancel(_request, _opts), do: {:error, :not_supported}
  end

  test "the TUI can detach during work and reattach to the same session" do
    suffix = System.unique_integer([:positive])
    opts = [name: :"tui-#{suffix}", registry: :"tui-reg-#{suffix}", sessions: :"tui-dyn-#{suffix}"]
    {:ok, pid} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    session = Identity.new!(:session)
    attach_opts = [registry: opts[:registry], supervisor: opts[:sessions]]

    assert {:ok, attached} = TUI.attach(session.id, attach_opts)
    handle = attached.handle
    assert {:ok, server} = Registry.lookup(session.id, opts[:registry])
    assert Process.alive?(server)
    assert :ok = TUI.detach(handle)
    assert Process.alive?(server)
    assert {:ok, again} = TUI.reattach(handle, attach_opts)
    assert again.handle.session.id == session.id
    refute again.handle.attachment.id == handle.attachment.id
  end

  test "active runtime work and its transcript survive a TUI detach" do
    suffix = System.unique_integer([:positive])
    opts = [name: :"live-tui-#{suffix}", registry: :"live-tui-reg-#{suffix}", sessions: :"live-tui-dyn-#{suffix}"]
    {:ok, supervisor} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)

    session = Identity.new!(:session)
    attach_opts = [registry: opts[:registry], supervisor: opts[:sessions]]

    assert {:ok, first_attach} = TUI.attach(session.id, attach_opts)
    first = first_attach.handle
    {:ok, server} = Registry.lookup(session.id, opts[:registry])
    on_exit(fn -> Server.stop(server) end)
    assert :ok = Client.configure_runtime(first, Runtime, :agent, test_pid: self())

    assert {:ok, %{request: request, receipt: turn_receipt, duplicate: false}} =
             Client.start_turn(first, "keep working", idempotency_key: "tui-detach-turn")

    assert_receive {:runtime_waiting, worker}

    assert {:ok, %{request: nil, receipt: ^turn_receipt, duplicate: true}} =
             Client.start_turn(first, "keep working", idempotency_key: "tui-detach-turn")

    refute_receive {:runtime_waiting, _second_worker}, 20

    assert {:error, {:idempotency_conflict, receipt_id}} =
             Client.start_turn(first, "changed", idempotency_key: "tui-detach-turn")

    assert receipt_id == turn_receipt["id"]

    assert :ok = TUI.detach(first)
    assert Process.alive?(server)

    assert {:ok, second_attach} = TUI.attach(session.id, attach_opts)
    second = second_attach.handle
    assert {:ok, %{configured?: true, active_request: ^request}} = Client.runtime_info(second)
    assert TUI.observe(second) == ["input_admitted", "run_started", "model_delta"]

    restored =
      State.new(nil, {80, 24},
        session_client: second,
        session_events: second_attach.events,
        session_request: request
      )

    assert State.active_request(restored) == request
    assert {:active, ^request, _turn, :streaming} = restored.activity
    assert State.active_turn(restored).assistant == "still running"

    send(worker, :finish)

    assert %Result{outcome: %Result.Ok{content: "still running"}} =
             Client.await(second, request)

    assert TUI.observe(second) == ["input_admitted", "run_started", "model_delta", "run_completed"]

    assert {:ok, snapshot} = Client.snapshot(second)
    assert snapshot["payload"]["state"]["outcomes"] |> List.last() |> get_in(["payload", "content"]) == "still running"
  end

  test "credential-bearing prompt metadata is rejected before runtime start" do
    suffix = System.unique_integer([:positive])

    opts = [
      name: :"sensitive-tui-#{suffix}",
      registry: :"sensitive-tui-reg-#{suffix}",
      sessions: :"sensitive-tui-dyn-#{suffix}"
    ]

    {:ok, supervisor} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)
    session = Identity.new!(:session)

    assert {:ok, attached} =
             TUI.attach(session.id, registry: opts[:registry], supervisor: opts[:sessions])

    assert :ok = Client.configure_runtime(attached.handle, Runtime, :agent, test_pid: self())

    assert {:error, {:sensitive_value_rejected, rejection}} =
             Client.start_turn(attached.handle, "safe prompt",
               idempotency_key: "sensitive-turn",
               turn_opts: [context: %{authorization: "REDACTED_TEST_VALUE"}]
             )

    assert rejection["redacted"] == true
    refute_receive {:runtime_waiting, _worker}, 20
    assert {:ok, snapshot} = Client.snapshot(attached.handle)
    assert snapshot["payload"]["state"]["sequence"] == 0
  end

  test "a turn retry resolves its receipt after owner restart without runtime setup" do
    suffix = System.unique_integer([:positive])

    opts = [
      name: :"restart-turn-#{suffix}",
      registry: :"restart-turn-reg-#{suffix}",
      sessions: :"restart-turn-dyn-#{suffix}"
    ]

    {:ok, supervisor} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)
    session = Identity.new!(:session)

    attach_opts = [
      registry: opts[:registry],
      supervisor: opts[:sessions],
      client_id: "restart-client"
    ]

    assert {:ok, first_attach} = TUI.attach(session.id, attach_opts)
    assert :ok = Client.configure_runtime(first_attach.handle, Runtime, :agent, test_pid: self())

    assert {:ok, %{request: _request, receipt: receipt, duplicate: false}} =
             Client.start_turn(first_attach.handle, "restart-safe", idempotency_key: "restart-turn-key")

    assert receipt["payload"]["admission_state"] == "started"
    assert_receive {:runtime_waiting, worker}
    assert {:ok, server} = Registry.lookup(session.id, opts[:registry])
    monitor = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^server, :killed}
    send(worker, :finish)

    assert {:ok, restarted_attach} = TUI.attach(session.id, attach_opts)

    assert {:ok, %{request: nil, receipt: ^receipt, duplicate: true}} =
             Client.start_turn(restarted_attach.handle, "restart-safe", idempotency_key: "restart-turn-key")

    refute_receive {:runtime_waiting, _second_worker}, 20

    assert {:error, {:idempotency_conflict, receipt_id}} =
             Client.start_turn(restarted_attach.handle, "changed", idempotency_key: "restart-turn-key")

    assert receipt_id == receipt["id"]
  end

  test "queued input restores and consumption commits before it returns" do
    suffix = System.unique_integer([:positive])

    opts = [
      name: :"restart-queue-#{suffix}",
      registry: :"restart-queue-reg-#{suffix}",
      sessions: :"restart-queue-dyn-#{suffix}"
    ]

    {:ok, supervisor} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)
    session = Identity.new!(:session)
    attach_opts = [registry: opts[:registry], supervisor: opts[:sessions], client_id: "queue-client"]

    assert {:ok, first} = TUI.attach(session.id, attach_opts)
    assert {:ok, input} = Client.steer(first.handle, "change course", idempotency_key: "queue-add")
    assert {:ok, server} = Registry.lookup(session.id, opts[:registry])
    monitor = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^server, :killed}

    assert {:ok, restarted} = TUI.attach(session.id, attach_opts)
    assert {:ok, snapshot} = Client.snapshot(restarted.handle)
    assert [%{"input_id" => input_id}] = snapshot["payload"]["state"]["queues"]["steering"]
    assert input_id == input.identity.id
    assert {:ok, replacement} = Registry.lookup(session.id, opts[:registry])

    assert {:error, :not_attached} =
             Server.consume_queued(replacement, "missing", :steering, input_id, "missing-client")

    assert {:error, {:unknown_queue, :other}} =
             Server.consume_queued(replacement, restarted.handle.client.id, :other, input_id, "bad-queue")

    assert {:ok, %{item: %{"input_id" => ^input_id}, duplicate: false, receipt: receipt}} =
             Server.consume_queued(replacement, restarted.handle.client.id, :steering, input_id, "queue-consume")

    assert Server.state(replacement).queues.steering == []

    assert {:ok, %{input_id: ^input_id, duplicate: true, receipt: ^receipt}} =
             Server.consume_queued(replacement, restarted.handle.client.id, :steering, input_id, "queue-consume")

    assert {:error, :queue_empty} =
             Server.consume_queued(replacement, restarted.handle.client.id, :steering, input_id, "queue-empty")
  end

  test "the TUI applies each direct event in sequence" do
    suffix = System.unique_integer([:positive])
    opts = [name: :"batch-tui-#{suffix}", registry: :"batch-tui-reg-#{suffix}", sessions: :"batch-tui-dyn-#{suffix}"]
    {:ok, supervisor} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)

    session = Identity.new!(:session)
    attach_opts = [registry: opts[:registry], supervisor: opts[:sessions]]
    assert {:ok, attached} = TUI.attach(session.id, attach_opts)

    state =
      State.new(nil, {80, 24},
        session_client: attached.handle,
        session_events: attached.events
      )

    assert {:ok, _input} =
             Client.send(attached.handle, "hello", idempotency_key: "tui-ack-input")

    assert_receive {:jido_console_session, attachment_id, {:event, event}}
    assert attachment_id == attached.handle.attachment.id

    invalid = put_in(event, ["payload", "sequence"], 9)
    assert {:error, :invalid_tui_event_order, ^state} = TUI.apply_event(attached.handle, state, invalid)

    assert {:ok, applied} = TUI.apply_event(attached.handle, state, event)
    assert applied.semantic_sequence == 1
    assert {:ok, [^event]} = Client.events(attached.handle)
  end

  test "the TUI can replay the complete event history" do
    suffix = System.unique_integer([:positive])

    opts = [
      name: :"replay-tui-#{suffix}",
      registry: :"replay-tui-reg-#{suffix}",
      sessions: :"replay-tui-dyn-#{suffix}"
    ]

    {:ok, supervisor} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)

    session = Identity.new!(:session)

    attach_opts = [registry: opts[:registry], supervisor: opts[:sessions]]

    assert {:ok, attached} = TUI.attach(session.id, attach_opts)

    state =
      State.new(nil, {80, 24},
        session_client: attached.handle,
        session_events: attached.events
      )

    assert {:ok, _input} =
             Client.send(attached.handle, "first", idempotency_key: "tui-replay-first")

    assert {:ok, _input} =
             Client.send(attached.handle, "second", idempotency_key: "tui-replay-second")

    assert_receive {:jido_console_session, _, {:event, _first}}
    assert_receive {:jido_console_session, _, {:event, _second}}

    assert {:ok, replayed} = TUI.replay(attached.handle, state)
    assert replayed.semantic_sequence == 2
    assert {:ok, events} = Client.events(attached.handle)
    assert Enum.map(events, & &1["payload"]["sequence"]) == [1, 2]
  end
end
