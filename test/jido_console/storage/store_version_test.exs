defmodule Jido.Console.Storage.StoreVersionTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Console.Storage.SQLite

  test "upgrades a valid version 2 store with a marker-only change" do
    root = Path.join(System.tmp_dir!(), "jido-store-version-#{System.unique_integer([:positive])}")
    path = Path.join(root, "console.sqlite3")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    writer = String.to_atom("store-version-#{System.unique_integer([:positive])}")
    assert {:ok, pid} = SQLite.start_link(name: writer, path: path, integrity_on_open: false)
    GenServer.stop(pid)

    assert {:ok, conn} = Sqlite3.open(path)
    assert :ok = Sqlite3.execute(conn, "PRAGMA user_version=2")
    assert :ok = Sqlite3.close(conn)

    assert {:ok, pid} = SQLite.start_link(name: writer, path: path, integrity_on_open: false)
    GenServer.stop(pid)

    assert {:ok, conn} = Sqlite3.open(path)
    assert {:ok, [[3]]} = query(conn, "PRAGMA user_version")

    assert {:ok, [["sessions"], ["thread_events"]]} =
             query(conn, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")

    assert :ok = Sqlite3.close(conn)
  end

  defp query(conn, sql) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        Sqlite3.fetch_all(conn, statement)
      after
        Sqlite3.release(conn, statement)
      end
    end
  end
end
