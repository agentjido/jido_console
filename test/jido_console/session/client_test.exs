defmodule Jido.Console.Session.ClientTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{Client, Command, Registry, Supervisor, View}
  alias Jido.Console.Session.Client.TUI
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor
  alias Jido.Console.Test.{ThreadBridge, ThreadResources}

  defmodule RejectingDynamicSupervisor do
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)
    def init(:ok), do: {:ok, nil}
    def handle_call({:start_child, _child}, _from, state), do: {:reply, {:error, :session_start_failed}, state}
  end

  setup do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "jido-client-#{suffix}")
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

    %{opts: opts, registry: registry}
  end

  test "attach returns one complete View and a small handle", %{opts: opts} do
    assert {:ok, %{handle: %Client{} = handle, view: %View{} = view}} = Client.attach("client-thread", opts)
    assert Client.thread_id(handle) == "client-thread"
    assert is_reference(Client.attachment_ref(handle))
    assert view.thread_id == "client-thread"
    assert view.status == :idle
  end

  test "the handle resolves a replacement owner for each command", %{opts: opts, registry: registry} do
    {:ok, %{handle: handle}} = Client.attach("replacement-thread", opts)
    {:ok, owner} = Registry.lookup("replacement-thread", registry)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert {:ok, %View{status: :idle}} = Client.status(handle)
    {:ok, replacement} = Registry.lookup("replacement-thread", registry)
    refute replacement == owner
  end

  test "a stable command can be retried without a second provider call", %{opts: opts} do
    {:ok, %{handle: handle}} = Client.attach("retry-thread", opts)

    assert {:ok, %Command{} = command} =
             Client.submit_command(handle, "hello", command_id: "stable-command", request_id: "stable-request")

    assert {:ok, %{duplicate: false}} = Client.run(handle, command)
    assert {:ok, %{duplicate: true}} = Client.run(handle, command)
    assert_receive {:provider_started, "retry-thread", "stable-request", bridge}
    refute_receive {:provider_started, "retry-thread", "stable-request", _other}, 50
    send(bridge, :finish)
  end

  test "detach stops delivery but does not stop the run", %{opts: opts} do
    {:ok, %{handle: handle}} = Client.attach("detach-thread", opts)
    attachment_ref = Client.attachment_ref(handle)
    assert :ok = Client.detach(handle)

    assert {:ok, _accepted} =
             Client.submit(handle, "hold", command_id: "detach-command", request_id: "detach-request")

    assert_receive {:provider_started, "detach-thread", "detach-request", bridge}
    refute_receive {:jido_console_view, ^attachment_ref, _view}, 50
    send(bridge, :finish)
  end

  test "two attachments receive independent complete views", %{opts: opts} do
    {:ok, %{handle: first}} = Client.attach("two-clients", opts)
    {:ok, %{handle: second}} = Client.attach("two-clients", opts)
    first_ref = Client.attachment_ref(first)
    second_ref = Client.attachment_ref(second)

    assert {:ok, _accepted} =
             Client.submit(first, "hello", command_id: "two-command", request_id: "two-request")

    assert_receive {:jido_console_view, ^first_ref, %View{revision: first_revision}}
    assert_receive {:jido_console_view, ^second_ref, %View{revision: second_revision}}
    assert first_revision == second_revision
    assert_receive {:provider_started, "two-clients", "two-request", bridge}
    send(bridge, :finish)
  end

  test "model selection is shared and locks after the first durable prompt", %{opts: opts} do
    {:ok, %{handle: first}} = Client.attach("shared-model", opts)
    {:ok, %{handle: second}} = Client.attach("shared-model", opts)

    assert {:ok, selected} = Client.select_model(first, "ollama:llama3.2")
    assert selected == %{"identity" => "ollama:llama3.2", "tier" => "beta", "locked" => false}
    assert {:ok, %View{model: ^selected}} = Client.status(second)

    assert {:ok, _accepted} =
             Client.submit(first, "hello", command_id: "model-command", request_id: "model-request")

    assert {:error, error} = Client.select_model(second, "openai:gpt-4.1-mini")
    assert Exception.message(error) =~ "locked"
    assert {:ok, %View{model: %{"locked" => true}}} = Client.status(second)
    assert_receive {:provider_started, "shared-model", "model-request", bridge}
    send(bridge, :finish)
  end

  test "malformed model selection returns an error tuple", %{opts: opts} do
    {:ok, %{handle: handle}} = Client.attach("malformed-model", opts)

    assert {:error, :invalid_command} = Client.select_model(handle, "ollama")
  end

  test "replacement owner restores the durable selected model", %{opts: opts, registry: registry} do
    opts = Keyword.put(opts, :model, "openai:gpt-4.1-mini")
    {:ok, %{handle: handle}} = Client.attach("replacement-model", opts)
    assert {:ok, _selected} = Client.select_model(handle, "ollama:llama3.2")

    {:ok, owner} = Registry.lookup("replacement-model", registry)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert {:ok, %View{model: model}} = Client.status(handle)
    assert model == %{"identity" => "ollama:llama3.2", "tier" => "beta", "locked" => false}
  end

  test "concurrent selection and submit use one serialized model outcome", %{opts: opts} do
    {:ok, %{handle: handle}} = Client.attach("model-race", opts)
    parent = self()

    select =
      Task.async(fn ->
        send(parent, {:ready, self()})
        receive do: (:go -> Client.select_model(handle, "ollama:llama3.2"))
      end)

    submit =
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> Client.submit(handle, "race", command_id: "race-command", request_id: "race-request")
        end
      end)

    assert_receive {:ready, select_pid}
    assert_receive {:ready, submit_pid}
    send(select_pid, :go)
    send(submit_pid, :go)

    select_result = Task.await(select)
    assert {:ok, _accepted} = Task.await(submit)
    assert {:ok, %View{model: model}} = Client.status(handle)

    case select_result do
      {:ok, %{"identity" => "ollama:llama3.2"}} ->
        assert model == %{"identity" => "ollama:llama3.2", "tier" => "beta", "locked" => true}

      {:error, error} ->
        assert Exception.message(error) =~ "locked"
        assert model == %{"identity" => "openai:gpt-4.1-mini", "tier" => "supported", "locked" => true}
    end

    assert_receive {:provider_started, "model-race", "race-request", bridge}
    send(bridge, :finish)
  end

  test "Command and View contain no process or framework runtime values", %{opts: opts} do
    {:ok, %{handle: handle, view: view}} = Client.attach("portable-thread", opts)
    {:ok, command} = Client.submit_command(handle, "portable", command_id: "portable", request_id: "request")

    refute runtime_value?(command)
    refute runtime_value?(view)
  end

  test "all control commands use the same small boundary", %{opts: opts} do
    {:ok, %{handle: handle}} = Client.attach("control-thread", opts)

    assert {:error, :stale_request} = Client.cancel(handle, "missing")
    assert {:error, :review_not_pending} = Client.approve(handle, "request", "review")
    assert {:error, :review_not_pending} = Client.deny(handle, "request", "review")
    assert {:ok, :removed} = Client.remove(handle, "missing")
    assert {:ok, %{events: []}} = Client.history(handle, limit: 10)
    assert {:ok, %{events: []}} = Client.history(handle, limit: 10, before_sequence: 20)
    assert :ok = Client.stop(handle)
  end

  test "reattach replaces the attachment and nil attachments detach safely", %{opts: opts} do
    {:ok, %{handle: handle}} = TUI.attach("reattach-thread", opts)
    old_ref = Client.attachment_ref(handle)
    assert TUI.observe(handle) == []
    assert {:ok, %{handle: replacement}} = TUI.reattach(handle)
    refute Client.attachment_ref(replacement) == old_ref
    assert :ok = TUI.detach(replacement)

    nil_handle = %Client{thread_id: "reattach-thread", attachment_ref: nil, owner_options: opts}
    assert :ok = Client.detach(nil_handle)

    other = Command.new!(id: "status", type: :status, thread_id: "other")
    assert {:error, :cross_thread_command} = Client.run(replacement, other)
  end

  test "missing session infrastructure is a clean detached state" do
    suffix = System.unique_integer([:positive])

    handle = %Client{
      thread_id: "missing-infrastructure",
      attachment_ref: make_ref(),
      owner_options: [
        registry: unique(:missing_registry, suffix),
        supervisor: unique(:missing_supervisor, suffix)
      ]
    }

    assert TUI.observe(handle) == []
    assert :ok = Client.detach(handle)
  end

  test "detach reports a session supervisor refusal" do
    suffix = System.unique_integer([:positive])
    {:ok, rejecting} = RejectingDynamicSupervisor.start_link()

    handle = %Client{
      thread_id: "rejected-infrastructure",
      attachment_ref: make_ref(),
      owner_options: [
        registry: unique(:missing_registry, suffix),
        supervisor: rejecting
      ]
    }

    assert {:error, :session_start_failed} = Client.detach(handle)
    GenServer.stop(rejecting)
  end

  defp runtime_value?(value) when is_pid(value) or is_reference(value) or is_port(value) or is_function(value), do: true
  defp runtime_value?(%module{}) when module in [Jidoka.Chat.Request, Jidoka.Session.Data], do: true
  defp runtime_value?(%_{} = value), do: value |> Map.from_struct() |> runtime_value?()

  defp runtime_value?(value) when is_map(value),
    do: Enum.any?(value, fn {key, item} -> runtime_value?(key) or runtime_value?(item) end)

  defp runtime_value?(value) when is_list(value), do: Enum.any?(value, &runtime_value?/1)
  defp runtime_value?(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.any?(&runtime_value?/1)
  defp runtime_value?(_value), do: false

  defp unique(label, suffix), do: String.to_atom("#{label}-#{suffix}")
end
