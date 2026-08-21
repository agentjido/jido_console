defmodule Jido.Console.StorageTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Console.Home
  alias Jido.Console.Storage
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor
  alias Jidoka.Agent
  alias Jidoka.Session.Data
  alias Jidoka.Session.Store

  setup do
    root = temp_root()
    opts = storage_options(root)

    assert {:ok, supervisor} = StorageSupervisor.start_link(opts)
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, opts: opts, supervisor: supervisor, store: Storage.session_store(storage_opts(opts))}
  end

  test "uses one private database with only sessions and thread_events", context do
    path = database_path(context.root)

    assert File.regular?(path)
    assert :ok = Home.check_private(path)

    assert {:ok, %{integrity: :ok, tables: 2, sessions: 0, thread_events: 0}} =
             Storage.inspect_store(storage_opts(context.opts))

    Supervisor.stop(context.supervisor)
    assert {:ok, conn} = Sqlite3.open(path)

    assert {:ok, statement} =
             Sqlite3.prepare(
               conn,
               "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
             )

    assert :ok = Sqlite3.bind(statement, [])
    assert {:ok, rows} = Sqlite3.fetch_all(conn, statement)
    assert Enum.map(rows, &hd/1) == ["sessions", "thread_events"]
    assert :ok = Sqlite3.release(conn, statement)
    assert :ok = Sqlite3.close(conn)
  end

  test "keeps validated sessions across writer restarts", context do
    session = session("stored-session")
    assert {:ok, ^session} = Store.put_session(context.store, session)

    Supervisor.stop(context.supervisor)
    assert {:ok, _supervisor} = StorageSupervisor.start_link(context.opts)

    store = Storage.session_store(storage_opts(context.opts))
    assert {:ok, ^session} = Store.get_session(store, session.session_id)
    assert {:ok, [^session]} = Store.list_sessions(store)
    assert {:ok, %{sessions: 1, thread_events: 0}} = Storage.status(storage_opts(context.opts))
  end

  test "rejects the removed events and operations schema", context do
    Supervisor.stop(context.supervisor)
    previous = Process.flag(:trap_exit, true)
    path = database_path(context.root)

    File.rm!(path)
    assert {:ok, conn} = Sqlite3.open(path)
    assert :ok = Sqlite3.execute(conn, "CREATE TABLE events(id TEXT PRIMARY KEY) STRICT")
    assert :ok = Sqlite3.execute(conn, "CREATE TABLE operations(id TEXT PRIMARY KEY) STRICT")
    assert :ok = Sqlite3.close(conn)
    assert :ok = File.chmod(path, Home.file_mode())

    assert {:error, reason} = StorageSupervisor.start_link(context.opts)
    assert inspect(reason) =~ "storage_schema_reset_required"
    Process.flag(:trap_exit, previous)
  end

  test "denies a second writer for the same home", context do
    previous = Process.flag(:trap_exit, true)

    second = [
      name: unique(:second_supervisor),
      lock: unique(:second_lock),
      writer: unique(:second_writer),
      jido_home: context.root
    ]

    assert {:error, _reason} = StorageSupervisor.start_link(second)
    Process.flag(:trap_exit, previous)
  end

  defp session(id) do
    {:ok, session} = Data.start(spec(), session_id: id)
    session
  end

  defp spec do
    Agent.Spec.new!(
      id: "storage-test-agent",
      instructions: "Test durable storage.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp database_path(root), do: Path.join(root, "state/console.sqlite3")
  defp storage_opts(opts), do: [writer: opts[:writer], deadline: 1_000]

  defp storage_options(root) do
    [
      name: unique(:supervisor),
      lock: unique(:lock),
      writer: unique(:writer),
      jido_home: root
    ]
  end

  defp temp_root, do: Path.join(System.tmp_dir!(), "jido-storage-#{System.unique_integer([:positive])}")
  defp unique(label), do: String.to_atom("#{label}-#{System.unique_integer([:positive])}")
end
