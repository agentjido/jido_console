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
    assert {:ok, request} = Client.start_turn(first, "keep working")
    assert_receive {:runtime_waiting, worker}

    assert :ok = TUI.detach(first)
    assert Process.alive?(server)

    assert {:ok, second_attach} = TUI.attach(session.id, attach_opts)
    second = second_attach.handle
    assert {:ok, %{configured?: true, active_request: ^request}} = Client.runtime_info(second)
    assert TUI.observe(second) == ["run_started", "model_delta"]

    restored =
      State.new(nil, {80, 24},
        session_snapshot: second_attach.snapshot,
        session_request: request
      )

    assert State.active_request(restored) == request
    assert {:active, ^request, _turn, :streaming} = restored.activity
    assert State.active_turn(restored).assistant == "still running"

    send(worker, :finish)

    assert %Result{outcome: %Result.Ok{content: "still running"}} =
             Client.await(second, request)

    assert TUI.observe(second) == ["run_started", "model_delta", "run_completed"]

    assert {:ok, snapshot} = Client.snapshot(second)
    assert snapshot["payload"]["state"]["outcomes"] |> List.last() |> get_in(["payload", "content"]) == "still running"
  end

  test "the TUI acknowledges only after a complete canonical batch applies" do
    suffix = System.unique_integer([:positive])
    opts = [name: :"batch-tui-#{suffix}", registry: :"batch-tui-reg-#{suffix}", sessions: :"batch-tui-dyn-#{suffix}"]
    {:ok, supervisor} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)

    session = Identity.new!(:session)
    attach_opts = [registry: opts[:registry], supervisor: opts[:sessions]]
    assert {:ok, attached} = TUI.attach(session.id, attach_opts)
    state = State.new(nil, {80, 24}, session_client: attached.handle, session_snapshot: attached.snapshot)

    assert {:ok, _input} = Client.send(attached.handle, "hello")
    assert_receive {:jido_console_session, attachment_id, :output_ready}
    assert attachment_id == attached.handle.attachment.id
    assert {:ok, batch} = Client.output(attached.handle)

    invalid = put_in(batch, ["payload", "events", Access.at(0), "payload", "sequence"], 9)
    assert {:error, :invalid_tui_event_order, ^state} = TUI.apply_batch(attached.handle, state, invalid)
    assert {:error, :ack_required} = Client.output(attached.handle)

    assert {:ok, applied} = TUI.apply_batch(attached.handle, state, batch)
    assert applied.semantic_sequence == 1
    assert :empty = Client.output(attached.handle)
  end

  test "the TUI performs snapshot suffix and resume recovery as one transaction" do
    suffix = System.unique_integer([:positive])

    opts = [
      name: :"recovery-tui-#{suffix}",
      registry: :"recovery-tui-reg-#{suffix}",
      sessions: :"recovery-tui-dyn-#{suffix}"
    ]

    {:ok, supervisor} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)

    session = Identity.new!(:session)

    attach_opts = [
      registry: opts[:registry],
      supervisor: opts[:sessions],
      delivery_limits: %{queue_count: 1}
    ]

    assert {:ok, attached} = TUI.attach(session.id, attach_opts)
    state = State.new(nil, {80, 24}, session_client: attached.handle, session_snapshot: attached.snapshot)
    assert {:ok, _input} = Client.send(attached.handle, "first")
    assert {:ok, _input} = Client.send(attached.handle, "second")
    assert_receive {:jido_console_session, _, :output_ready}

    assert {:ok, recovered} = TUI.consume(attached.handle, state)
    assert recovered.semantic_sequence == 2
    assert :empty = Client.output(attached.handle)
  end

  test "the production loop has no raw runtime receive route" do
    source = File.read!("lib/jido_console/cli/tui.ex")

    for raw <- ["session_runtime_", "session_control_result", "{:jidoka,", "{:session_updated,", "{:session_gap,"] do
      refute source =~ raw
    end
  end
end
