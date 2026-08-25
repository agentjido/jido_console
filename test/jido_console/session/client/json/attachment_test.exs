defmodule Jido.Console.Session.Client.JSON.AttachmentTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{Client, Registry, Supervisor, View}
  alias Jido.Console.Session.Client.JSON.Attachment
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor
  alias Jido.Console.Test.{ThreadBridge, ThreadResources}

  setup do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "jido-json-attachment-#{suffix}")
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

  test "keeps one latest pending view and reports skipped revisions", %{opts: opts} do
    {:ok, pid, %{attachment_id: "attachment-1"}} =
      Attachment.start_link(
        driver: self(),
        thread_id: "coalesce-thread",
        owner_options: opts,
        id_generator: fn _prefix -> "attachment-1" end
      )

    assert_receive {:json_attachment_ready, ^pid}
    assert {:ok, %{view: %View{revision: 0}, gap: nil}} = Attachment.take_view(pid)

    state = :sys.get_state(pid)
    attachment_ref = Client.attachment_ref(state.handle)

    for revision <- 1..3 do
      send(
        pid,
        {:jido_console_view, attachment_ref,
         View.new!(thread_id: "coalesce-thread", status: :running, revision: revision)}
      )
    end

    assert_receive {:json_attachment_ready, ^pid}
    assert {:ok, %{view: %View{revision: 3}, gap: {1, 2}}} = Attachment.take_view(pid)
    assert :empty = Attachment.take_view(pid)
    Attachment.close(pid)
  end

  test "automatically attaches to a replacement owner", %{opts: opts, registry: registry} do
    {:ok, ids} = Agent.start_link(fn -> 0 end)

    id_generator = fn _prefix ->
      index = Agent.get_and_update(ids, fn value -> {value, value + 1} end)
      "attachment-#{index}"
    end

    {:ok, pid, %{attachment_id: "attachment-0"}} =
      Attachment.start_link(
        driver: self(),
        thread_id: "restart-thread",
        owner_options: opts,
        id_generator: id_generator
      )

    assert_receive {:json_attachment_ready, ^pid}
    assert {:ok, _initial} = Attachment.take_view(pid)
    {:ok, owner} = Registry.lookup("restart-thread", registry)
    Process.exit(owner, :kill)

    assert_receive {:json_attachment_lifecycle, ^pid, :reattaching, reattaching}, 2_000
    assert reattaching.previous_attachment_id == "attachment-0"

    assert_receive {:json_attachment_lifecycle, ^pid, :reattached, reattached}, 2_000
    assert reattached.attachment_id == "attachment-1"
    assert reattached.previous_attachment_id == "attachment-0"
    assert_receive {:json_attachment_ready, ^pid}, 2_000
    assert {:ok, %{attachment_id: "attachment-1", view: %View{status: :idle}}} = Attachment.take_view(pid)
    Attachment.close(pid)
  end

  defp unique(label, suffix), do: String.to_atom("#{label}-#{suffix}")
end
