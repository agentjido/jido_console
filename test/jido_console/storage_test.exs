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

  test "preserves and replaces the removed events and operations schema", context do
    Supervisor.stop(context.supervisor)
    path = database_path(context.root)

    create_legacy_store(path)
    sidecars = create_legacy_wal_sidecars(path)
    on_exit(fn -> Sqlite3.close(sidecars.reader) end)

    assert {:ok, replacement} = StorageSupervisor.start_link(context.opts)

    assert {:ok, %{integrity: :ok, tables: 2, sessions: 0, thread_events: 0}} =
             Storage.inspect_store(storage_opts(context.opts))

    backup = path <> ".schema-1-backup"
    backup_database = Path.join(backup, "console.sqlite3")
    backup_wal = Path.join(backup, "console.sqlite3-wal")
    backup_shm = Path.join(backup, "console.sqlite3-shm")

    assert File.dir?(backup)
    assert File.regular?(backup_database)
    assert :ok = Home.check_private(backup)
    assert :ok = Home.check_private(backup_database)
    assert File.read!(backup_wal) == sidecars.wal
    assert File.stat!(backup_shm).inode == sidecars.shm_inode
    assert :ok = Home.check_private(backup_wal)
    assert :ok = Home.check_private(backup_shm)
    assert database_version_and_tables(backup_database) == {1, ["events", "operations"]}
    assert table_rows(backup_database, "events") == [["legacy-event"], ["legacy-wal-event"]]
    assert table_rows(backup_database, "operations") == [["legacy-operation"]]

    Supervisor.stop(replacement)
  end

  test "recovers an interrupted backup before opening a replacement store", context do
    Supervisor.stop(context.supervisor)
    path = database_path(context.root)
    backup = path <> ".schema-1-backup"
    backup_database = Path.join(backup, "console.sqlite3")
    marker = Path.join(backup, ".in-progress")
    source_wal = path <> "-wal"
    source_shm = path <> "-shm"
    backup_wal = Path.join(backup, "console.sqlite3-wal")
    backup_shm = Path.join(backup, "console.sqlite3-shm")

    create_legacy_store(path)
    File.mkdir!(backup)
    File.chmod!(backup, Home.directory_mode())
    File.rename!(path, backup_database)
    File.write!(marker, "in-progress\n")
    File.chmod!(marker, Home.file_mode())
    File.write!(source_wal, "legacy-wal")
    File.chmod!(source_wal, Home.file_mode())
    File.write!(source_shm, "legacy-shm")
    File.chmod!(source_shm, Home.file_mode())

    assert {:ok, replacement} = StorageSupervisor.start_link(context.opts)

    assert File.regular?(backup_database)
    refute File.exists?(marker)
    assert File.read!(backup_wal) == "legacy-wal"
    assert File.read!(backup_shm) == "legacy-shm"
    assert :ok = Home.check_private(backup_wal)
    assert :ok = Home.check_private(backup_shm)
    assert table_rows(backup_database, "events") == [["legacy-event"]]
    assert table_rows(backup_database, "operations") == [["legacy-operation"]]

    assert {:ok, %{integrity: :ok, tables: 2, sessions: 0, thread_events: 0}} =
             Storage.inspect_store(storage_opts(context.opts))

    Supervisor.stop(replacement)
  end

  test "rolls back when a sidecar is not a regular file", context do
    Supervisor.stop(context.supervisor)
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    path = database_path(context.root)
    backup = path <> ".schema-1-backup"
    sidecar = path <> "-shm"
    sidecar_target = Path.join(context.root, "sidecar-target")

    create_legacy_store(path)
    File.write!(sidecar_target, "keep")
    File.chmod!(sidecar_target, Home.file_mode())
    assert :ok = File.ln_s(sidecar_target, sidecar)

    assert {:error, reason} = StorageSupervisor.start_link(context.opts)
    assert inspect(reason) =~ "storage_schema_backup_failed"
    assert File.regular?(path)
    assert database_version_and_tables(path) == {1, ["events", "operations"]}
    assert File.read!(sidecar_target) == "keep"
    assert {:ok, %{type: :symlink}} = File.lstat(sidecar)
    refute File.exists?(Path.join(backup, "console.sqlite3"))
    refute File.exists?(backup)
  end

  test "completes a backup interrupted after all files moved", context do
    Supervisor.stop(context.supervisor)
    path = database_path(context.root)
    backup = path <> ".schema-1-backup"
    backup_database = Path.join(backup, "console.sqlite3")
    marker = Path.join(backup, ".in-progress")

    create_legacy_store(path)
    File.mkdir!(backup)
    File.chmod!(backup, Home.directory_mode())
    File.rename!(path, backup_database)
    File.write!(marker, "in-progress\n")
    File.chmod!(marker, Home.file_mode())

    assert {:ok, replacement} = StorageSupervisor.start_link(context.opts)

    refute File.exists?(marker)
    assert table_rows(backup_database, "events") == [["legacy-event"]]
    assert table_rows(backup_database, "operations") == [["legacy-operation"]]

    assert {:ok, %{integrity: :ok, tables: 2, sessions: 0, thread_events: 0}} =
             Storage.inspect_store(storage_opts(context.opts))

    Supervisor.stop(replacement)
  end

  test "rejects an unsafe target while recovering an interrupted backup", context do
    Supervisor.stop(context.supervisor)
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    path = database_path(context.root)
    backup = path <> ".schema-1-backup"
    backup_database = Path.join(backup, "console.sqlite3")
    marker = Path.join(backup, ".in-progress")
    target = Path.join(context.root, "backup-target")

    File.rm!(path)
    File.mkdir!(backup)
    File.chmod!(backup, Home.directory_mode())
    File.write!(marker, "in-progress\n")
    File.chmod!(marker, Home.file_mode())
    File.write!(target, "keep")
    File.chmod!(target, Home.file_mode())
    assert :ok = File.ln_s(target, backup_database)

    assert {:error, reason} = StorageSupervisor.start_link(context.opts)
    assert inspect(reason) =~ "storage_schema_backup_failed"
    assert {:ok, %{type: :symlink}} = File.lstat(backup_database)
    assert File.read!(target) == "keep"
    refute File.exists?(path)
  end

  test "does not replace a legacy store when its backup path exists", context do
    Supervisor.stop(context.supervisor)
    previous = Process.flag(:trap_exit, true)
    path = database_path(context.root)
    backup = path <> ".schema-1-backup"
    marker = Path.join(backup, "preserved")

    create_legacy_store(path)
    File.mkdir!(backup)
    File.chmod!(backup, Home.directory_mode())
    File.write!(marker, "keep")

    assert {:error, reason} = StorageSupervisor.start_link(context.opts)
    assert inspect(reason) =~ "storage_schema_backup_exists"
    assert database_version_and_tables(path) == {1, ["events", "operations"]}
    assert File.read!(marker) == "keep"

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

  defp create_legacy_store(path) do
    File.rm!(path)
    assert {:ok, conn} = Sqlite3.open(path)
    assert :ok = Sqlite3.execute(conn, "CREATE TABLE events(id TEXT PRIMARY KEY) STRICT")
    assert :ok = Sqlite3.execute(conn, "CREATE TABLE operations(id TEXT PRIMARY KEY) STRICT")
    assert :ok = Sqlite3.execute(conn, "INSERT INTO events(id) VALUES ('legacy-event')")
    assert :ok = Sqlite3.execute(conn, "INSERT INTO operations(id) VALUES ('legacy-operation')")
    assert :ok = Sqlite3.execute(conn, "PRAGMA user_version=1")
    assert :ok = Sqlite3.close(conn)
    assert :ok = File.chmod(path, Home.file_mode())
  end

  defp create_legacy_wal_sidecars(path) do
    assert {:ok, writer} = Sqlite3.open(path)
    assert :ok = Sqlite3.execute(writer, "PRAGMA journal_mode=WAL")
    assert {:ok, reader} = Sqlite3.open(path)

    assert {:ok, statement} = Sqlite3.prepare(reader, "SELECT id FROM events")
    assert :ok = Sqlite3.bind(statement, [])
    assert {:ok, _rows} = Sqlite3.fetch_all(reader, statement)
    assert :ok = Sqlite3.release(reader, statement)

    assert :ok = Sqlite3.execute(writer, "INSERT INTO events(id) VALUES ('legacy-wal-event')")
    assert :ok = Sqlite3.close(writer)
    assert File.regular?(path <> "-wal")
    assert File.regular?(path <> "-shm")

    %{
      reader: reader,
      wal: File.read!(path <> "-wal"),
      shm_inode: File.stat!(path <> "-shm").inode
    }
  end

  defp database_version_and_tables(path) do
    assert {:ok, conn} = Sqlite3.open(path)

    assert {:ok, statement} =
             Sqlite3.prepare(
               conn,
               "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
             )

    assert :ok = Sqlite3.bind(statement, [])
    assert {:ok, rows} = Sqlite3.fetch_all(conn, statement)
    assert :ok = Sqlite3.release(conn, statement)

    assert {:ok, version_statement} = Sqlite3.prepare(conn, "PRAGMA user_version")
    assert :ok = Sqlite3.bind(version_statement, [])
    assert {:ok, [[version]]} = Sqlite3.fetch_all(conn, version_statement)
    assert :ok = Sqlite3.release(conn, version_statement)
    assert :ok = Sqlite3.close(conn)

    {version, Enum.map(rows, &hd/1)}
  end

  defp table_rows(path, table) do
    assert {:ok, conn} = Sqlite3.open(path)

    assert {:ok, statement} = Sqlite3.prepare(conn, "SELECT id FROM #{table} ORDER BY id")
    assert :ok = Sqlite3.bind(statement, [])
    assert {:ok, rows} = Sqlite3.fetch_all(conn, statement)
    assert :ok = Sqlite3.release(conn, statement)
    assert :ok = Sqlite3.close(conn)

    rows
  end

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
