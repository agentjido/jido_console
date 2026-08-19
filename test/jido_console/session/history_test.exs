defmodule Jido.Console.Session.HistoryTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{Event, Generation, History, Reducer, State}
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor

  setup do
    root = Path.join(System.tmp_dir!(), "jido-history-#{System.unique_integer([:positive])}")
    opts = [name: unique(:supervisor), lock: unique(:lock), writer: unique(:writer), jido_home: root]
    assert {:ok, supervisor} = StorageSupervisor.start_link(opts)
    on_exit(fn -> File.rm_rf(root) end)
    %{opts: opts, supervisor: supervisor}
  end

  test "replays the complete event log after restart", context do
    session_id = "history-replay"
    {:ok, owner} = Generation.claim(session_id)
    first = event(session_id, 1, "run_started")
    {:ok, first_state} = Reducer.apply_event(State.new(session_id), first)
    assert {:ok, %{sequence: 1}} = History.append(first, first_state, owner, storage_opts(context.opts))

    second = event(session_id, 2, "run_completed")
    {:ok, second_state} = Reducer.apply_event(first_state, second)
    assert {:ok, %{sequence: 2}} = History.append(second, second_state, owner, storage_opts(context.opts))

    Supervisor.stop(context.supervisor)
    assert {:ok, _supervisor} = StorageSupervisor.start_link(context.opts)

    assert {:ok, rebuilt} = History.rebuild(session_id, storage_opts(context.opts))
    assert rebuilt.events == 2
    assert rebuilt.state == second_state
    refute rebuilt.interrupted
  end

  test "does not resume an incomplete run", context do
    session_id = "history-interrupted"
    {:ok, owner} = Generation.claim(session_id)
    event = event(session_id, 1, "run_started")
    {:ok, state} = Reducer.apply_event(State.new(session_id), event)
    assert {:ok, _result} = History.append(event, state, owner, storage_opts(context.opts))

    assert {:ok, rebuilt} = History.rebuild(session_id, storage_opts(context.opts))
    assert rebuilt.interrupted
    assert is_nil(rebuilt.state.active_run)
    assert rebuilt.state.sequence == 1
  end

  defp event(session_id, sequence, type) do
    {:ok, event} =
      Event.classify(%{
        "id" => "#{session_id}-#{sequence}",
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
