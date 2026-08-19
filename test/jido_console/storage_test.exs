defmodule Jido.Console.StorageTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Jido.Console.Session.{Event, Reducer, State}
  alias Jido.Console.Storage
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor

  setup do
    root = Path.join(System.tmp_dir!(), "jido-storage-#{System.unique_integer([:positive])}")

    opts = [
      name: unique(:supervisor),
      lock: unique(:lock),
      writer: unique(:writer),
      jido_home: root
    ]

    assert {:ok, supervisor} = StorageSupervisor.start_link(opts)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, opts: opts, supervisor: supervisor}
  end

  test "uses one private database with three product tables", context do
    path = Path.join(context.root, "state/console.sqlite3")
    assert File.regular?(path)
    assert {:ok, %{integrity: :ok, tables: 3}} = Storage.inspect_store(storage_opts(context.opts))

    Supervisor.stop(context.supervisor)
    assert {:ok, conn} = Sqlite3.open(path)
    assert {:ok, statement} = Sqlite3.prepare(conn, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    assert :ok = Sqlite3.bind(statement, [])
    assert {:ok, rows} = Sqlite3.fetch_all(conn, statement)
    assert Enum.map(rows, &hd/1) == ["credential_profiles", "events", "operations"]
    assert :ok = Sqlite3.release(conn, statement)
    assert :ok = Sqlite3.close(conn)
  end

  test "commits ordered events and reads them after restart", context do
    event = event("session-one", 1, "event-one", "input_admitted")
    {:ok, semantic} = Reducer.apply_event(State.new("session-one"), event)

    assert {:ok, %{sequence: 1, duplicate: false}} =
             Storage.append_event(event, semantic, storage_opts(context.opts))

    assert {:ok, %{sequence: 1}} = Storage.history_head("session-one", storage_opts(context.opts))
    assert {:ok, [^event]} = Storage.events("session-one", storage_opts(context.opts))

    Supervisor.stop(context.supervisor)
    assert {:ok, _supervisor} = StorageSupervisor.start_link(context.opts)
    assert {:ok, [^event]} = Storage.events("session-one", storage_opts(context.opts))
    assert {:ok, %{events: 1, operations: 0, profiles: 0}} = Storage.status(storage_opts(context.opts))
  end

  test "rejects event gaps and changed duplicate identities", context do
    gap = event("session-gap", 2, "event-gap", "input_admitted")
    semantic = %{State.new("session-gap") | sequence: 2}

    assert {:error, {:invalid_event_sequence, "session-gap", 0, 2}} =
             Storage.append_event(gap, semantic, storage_opts(context.opts))

    first = event("session-conflict", 1, "shared-event", "input_admitted")
    {:ok, first_state} = Reducer.apply_event(State.new("session-conflict"), first)
    assert {:ok, %{duplicate: false}} = Storage.append_event(first, first_state, storage_opts(context.opts))
    assert {:ok, %{duplicate: true}} = Storage.append_event(first, first_state, storage_opts(context.opts))

    changed = event("session-conflict", 1, "shared-event", "run_started")
    {:ok, changed_state} = Reducer.apply_event(State.new("session-conflict"), changed)

    assert {:error, {:canonical_event_conflict, "shared-event"}} =
             Storage.append_event(changed, changed_state, storage_opts(context.opts))
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

  defp event(session_id, sequence, id, type) do
    {:ok, event} =
      Event.classify(%{
        "id" => id,
        "session_id" => session_id,
        "type" => type,
        "sequence" => sequence,
        "durability" => "process",
        "sensitivity" => "public",
        "origin" => %{"kind" => "session", "actor_id" => session_id},
        "trust" => %{"evidence" => "test", "policy" => "test"}
      })

    event
  end

  defp storage_opts(opts), do: [writer: opts[:writer], deadline: 1_000]
  defp unique(label), do: String.to_atom("#{label}-#{System.unique_integer([:positive])}")
end
