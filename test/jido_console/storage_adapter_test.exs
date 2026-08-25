defmodule Jido.Console.StorageAdapterTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.Event
  alias Jido.Console.Storage
  alias Jido.Console.Storage.SQLite
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor

  defmodule TestAdapter do
    @behaviour Jido.Console.Storage.Adapter

    @impl true
    def start_link(opts) do
      report(opts, {:adapter_started, opts})
      Agent.start_link(fn -> :ready end, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def session_store(owner, opts) do
      report(opts, {:session_store, owner, opts})
      {__MODULE__, pid: owner, call_timeout: Keyword.fetch!(opts, :call_timeout)}
    end

    @impl true
    def append_thread_event(owner, event, opts) do
      report(opts, {:append_thread_event, owner, event, opts})
      {:ok, %{event: event, duplicate: false}}
    end

    @impl true
    def thread_events(owner, thread_id, opts) do
      report(opts, {:thread_events, owner, thread_id, opts})
      {:ok, %{events: [], history_truncated?: false}}
    end

    @impl true
    def open_thread_items(owner, thread_id, opts) do
      report(opts, {:open_thread_items, owner, thread_id, opts})
      {:ok, []}
    end

    @impl true
    def request_events(owner, thread_id, request_id, opts) do
      report(opts, {:request_events, owner, thread_id, request_id, opts})
      {:ok, []}
    end

    @impl true
    def inspect_store(owner, opts) do
      report(opts, {:inspect_store, owner, opts})
      {:ok, %{integrity: :ok}}
    end

    @impl true
    def status(owner, opts) do
      report(opts, {:status, owner, opts})
      {:ok, %{adapter: __MODULE__}}
    end

    defp report(opts, message) do
      if observer = Keyword.get(opts, :observer), do: send(observer, message)
    end
  end

  test "uses SQLite as the default adapter" do
    assert Storage.adapter() == SQLite
    assert {SQLite, store_opts} = Storage.session_store(writer: :default_adapter_writer, deadline: 123)
    assert store_opts[:pid] == :default_adapter_writer
    assert store_opts[:call_timeout] == 123
  end

  test "routes the public storage API through the selected adapter" do
    writer = unique(:adapter_writer)

    opts = [
      adapter: TestAdapter,
      writer: writer,
      observer: self(),
      marker: :configured,
      deadline: 25
    ]

    event =
      Event.new!(
        id: "event-1",
        session_id: "thread-1",
        queue_item_id: "item-1",
        request_id: "request-1",
        type: "prompt_queued"
      )

    assert {TestAdapter, store_opts} = Storage.session_store(opts)
    assert store_opts[:pid] == writer
    assert store_opts[:call_timeout] == 25
    assert_receive {:session_store, ^writer, session_opts}
    assert session_opts[:marker] == :configured

    assert {:ok, %{event: ^event, duplicate: false}} = Storage.append_thread_event(event, opts)
    assert_receive {:append_thread_event, ^writer, ^event, append_opts}
    assert append_opts[:call_timeout] == 25

    assert {:ok, %{events: [], history_truncated?: false}} = Storage.thread_events("thread-1", opts)
    assert_receive {:thread_events, ^writer, "thread-1", _opts}

    assert {:ok, []} = Storage.open_thread_items("thread-1", opts)
    assert_receive {:open_thread_items, ^writer, "thread-1", _opts}

    assert {:ok, []} = Storage.request_events("thread-1", "request-1", opts)
    assert_receive {:request_events, ^writer, "thread-1", "request-1", _opts}

    assert {:ok, %{integrity: :ok}} = Storage.inspect_store(opts)
    assert_receive {:inspect_store, ^writer, _opts}

    assert {:ok, %{adapter: TestAdapter}} = Storage.status(opts)
    assert_receive {:status, ^writer, _opts}
  end

  test "starts the selected adapter under the storage supervisor" do
    root = Path.join(System.tmp_dir!(), "jido-storage-adapter-#{System.unique_integer([:positive])}")
    writer = unique(:supervised_adapter)

    opts = [
      adapter: TestAdapter,
      name: unique(:storage_supervisor),
      lock: unique(:storage_lock),
      writer: writer,
      observer: self(),
      marker: :supervised,
      jido_home: root
    ]

    assert {:ok, supervisor} = StorageSupervisor.start_link(opts)
    assert_receive {:adapter_started, started_opts}
    assert started_opts[:name] == writer
    assert started_opts[:marker] == :supervised
    assert started_opts[:integrity_on_open]
    assert is_pid(Process.whereis(writer))

    Supervisor.stop(supervisor)
    File.rm_rf!(root)
  end

  defp unique(label), do: String.to_atom("#{label}-#{System.unique_integer([:positive])}")
end
