defmodule Jido.Console.Session.ThreadTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{Command, Queue, Thread, View}

  defmodule Resources do
    def new(thread_id, agent, _opts) do
      {:ok, spec} = Jidoka.Agent.Spec.from_input(agent)
      {:ok, %{thread_id: thread_id, spec: spec}}
    end

    def base_spec(resources), do: resources.spec
    def configure_model(resources, identity), do: {:ok, Map.put(resources, :model, identity)}
    def status(_resources), do: %{"status" => "ready"}
    def close(_resources), do: :ok
  end

  defmodule FailingStore do
    @behaviour Jidoka.Session.Store

    def put_session(_session, _opts), do: {:error, :store_failed}
    def get_session(_session_id, _opts), do: {:error, :store_failed}
    def list_sessions(_opts), do: {:ok, []}
  end

  defmodule SilentWriter do
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, nil}
    def handle_call(_message, _from, state), do: {:noreply, state}
  end

  defmodule CancelController do
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, nil}
    def handle_call({:cancel, _grace_ms}, _from, state), do: {:reply, {:ok, :cancelled}, state}
  end

  test "partial events stay ordered and publish as one complete coalesced view" do
    run_ref = make_ref()
    state = state(run_ref)
    {attachment_ref, _view, state} = View.attach(state, self())

    state =
      Enum.reduce(1..3, state, fn sequence, state ->
        event =
          Jidoka.Event.build(:llm_delta, [],
            request_id: "request-1",
            seq: sequence,
            data: %{text: Integer.to_string(sequence)}
          )

        Thread.bridge_event(state, run_ref, "request-1", event)
      end)

    refute_receive {:jido_console_view, ^attachment_ref, _view}
    assert Enum.map(View.from_thread(state).partial, & &1.seq) == [1, 2, 3]
    assert is_reference(state.partial_publish_token)

    token = state.partial_publish_token
    state = Thread.publish_partial(state, run_ref, token)

    assert_receive {:jido_console_view, ^attachment_ref, %View{} = published}
    assert Enum.map(published.partial, & &1.seq) == [1, 2, 3]
    refute_receive {:jido_console_view, ^attachment_ref, _view}

    next_run = make_ref()
    next_state = %{state | bridge: %{run_ref: next_run}}
    assert Thread.publish_partial(next_state, run_ref, token) == next_state
  end

  test "ignores malformed and stale bridge events" do
    run_ref = make_ref()
    state = state(run_ref)

    oversized =
      Jidoka.Event.build(:llm_delta, [],
        request_id: "request-1",
        seq: 0,
        data: %{blob: String.duplicate("x", 5_000)}
      )

    assert Thread.bridge_event(state, run_ref, "request-1", oversized) == state
    assert Thread.bridge_event(state, make_ref(), "request-1", oversized) == state
    assert Thread.bridge_handle(state, self(), make_ref(), "request-1", :handle) == state
  end

  test "keeps an early cancellation pending when its request handle is invalid" do
    state = state(make_ref()) |> Map.put(:bridge, nil)
    cancel = Command.new!(id: "cancel-1", type: :cancel, thread_id: "thread-1", request_id: "request-1")

    assert {:reply, {:ok, :requested}, pending} = Thread.command(cancel, state)
    assert pending.bridge.pending_cancel?

    pending = Thread.bridge_handle(pending, nil, nil, "request-1", :invalid_handle)
    assert pending.bridge.handle == :invalid_handle
    assert pending.bridge.pending_cancel?
  end

  test "reports an invalid cancellation handle and clears a valid pending cancellation" do
    run_ref = make_ref()
    cancel = Command.new!(id: "cancel-1", type: :cancel, thread_id: "thread-1", request_id: "request-1")

    invalid =
      state(run_ref)
      |> Map.put(:bridge, %{
        pid: self(),
        run_ref: run_ref,
        handle: :invalid_handle,
        pending_cancel?: false,
        kind: :prompt
      })

    assert {:reply, {:error, :invalid_async_request}, ^invalid} = Thread.command(cancel, invalid)

    {:ok, controller} = CancelController.start_link()

    request =
      Jidoka.Chat.Request.new(
        request_id: "request-1",
        controller: controller,
        target: :test,
        session_id: "thread-1",
        stream_to: nil,
        started_at_ms: 0,
        metadata: %{}
      )

    pending = put_in(invalid, [:bridge, :handle], nil) |> put_in([:bridge, :pending_cancel?], true)
    cancelled = Thread.bridge_handle(pending, self(), run_ref, "request-1", request)
    refute cancelled.bridge.pending_cancel?
    GenServer.stop(controller)
  end

  test "keeps a queued item when its durable removal fails" do
    {:ok, queue} = Queue.push(Queue.new(), item("queued", "queued-request"))

    state =
      state(make_ref())
      |> Map.merge(%{
        queue: queue,
        storage_opts: [writer: :missing_remove_writer, deadline: 1]
      })

    remove = Command.new!(id: "remove", type: :remove, thread_id: "thread-1", queue_item_id: "queued")
    assert {:reply, {:error, :storage_unavailable}, unchanged} = Thread.command(remove, state)
    assert Queue.size(unchanged.queue) == 1
  end

  test "returns storage errors for a new item and a full-queue retry" do
    missing = [writer: :missing_thread_test_writer, deadline: 1]
    command = submit_command("item-2", "request-2")

    assert {:reply, {:error, :storage_unavailable}, unchanged} =
             state(make_ref())
             |> Map.merge(%{active: nil, bridge: nil, storage_opts: missing})
             |> then(&Thread.command(command, &1))

    assert unchanged.active == nil
    refute unchanged.model_locked?

    {:ok, full_queue} = Queue.push(Queue.new(1), item("queued", "queued-request"))

    full =
      state(make_ref())
      |> Map.merge(%{queue: full_queue, storage_opts: missing})

    assert {:reply, {:error, :storage_unavailable}, ^full} = Thread.command(command, full)
  end

  test "marks an ambiguous durable start failure unavailable" do
    {:ok, writer} = SilentWriter.start_link()
    bridge = spawn(fn -> Process.sleep(:infinity) end)
    Process.link(bridge)
    ref = Process.monitor(bridge)
    run_ref = make_ref()

    state =
      state(run_ref)
      |> Map.merge(%{
        bridge: %{pid: bridge, run_ref: run_ref, handle: nil, pending_cancel?: false, kind: :prompt},
        storage_opts: [writer: writer, deadline: 1]
      })

    failed = Thread.bridge_linked(state, bridge, run_ref)
    assert failed.status == :unavailable
    assert failed.error != nil
    assert_receive {:DOWN, ^ref, :process, ^bridge, :shutdown}
    GenServer.stop(writer)
  end

  test "propagates session store errors during initialization and reconciliation" do
    opts = [
      thread_id: "thread-failed-store",
      resources_module: Resources,
      store: {FailingStore, []},
      writer: :missing_thread_test_writer,
      deadline: 1
    ]

    assert {:error, :store_failed} = Thread.init(opts)

    state = state(make_ref()) |> Map.put(:store, {FailingStore, []})
    assert {:error, :store_failed, ^state} = Thread.reconcile(state)
    assert :ok = Thread.close(state)
  end

  defp state(run_ref) do
    spec = Jidoka.Agent.Spec.new!(id: "thread-agent", instructions: "Test.", model: %{provider: :test, id: "model"})
    {:ok, session} = Jidoka.Session.Data.start(spec, session_id: "thread-1")

    %{
      thread_id: "thread-1",
      status: :running,
      revision: 0,
      session: session,
      history: [],
      history_truncated?: false,
      partial: [],
      partial_publish_ref: nil,
      partial_publish_token: nil,
      partial_publish_run_ref: nil,
      active: %{id: "item-1", request_id: "request-1", text: "hello"},
      bridge: %{run_ref: run_ref},
      review: nil,
      queue: Queue.new(),
      resources_module: Resources,
      resources: %{},
      model_catalog: [],
      model: %{identity: "openai:gpt-4.1-mini", tier: :supported},
      model_locked?: false,
      error: nil,
      subscribers: %{},
      monitors: %{},
      options: [partial_publish_interval_ms: 1_000],
      store: {FailingStore, []},
      storage_opts: [writer: :missing_thread_test_writer, deadline: 1],
      task_supervisor: :missing_task_supervisor,
      bridge_module: Jido.Console.Session.JidokaBridge,
      wake_ref: nil
    }
  end

  defp submit_command(queue_item_id, request_id) do
    Command.new!(
      id: "submit-#{queue_item_id}",
      type: :submit,
      thread_id: "thread-1",
      queue_item_id: queue_item_id,
      request_id: request_id,
      text: "prompt"
    )
  end

  defp item(id, request_id) do
    command = submit_command(id, request_id)
    Command.item(command, Command.digest(command))
  end
end
