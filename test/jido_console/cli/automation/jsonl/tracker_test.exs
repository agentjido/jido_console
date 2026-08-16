defmodule Jido.Console.Automation.JSONL.TrackerTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Automation.JSONL.Tracker

  test "reserves only planned results and commits only the reservation" do
    assert {:ok, tracker} = Tracker.start(manifest(), fn -> "2026-08-12T12:00:00Z" end)

    unknown = result() |> Map.put(:cell_id, "other") |> Map.put(:sequence, 2)

    assert {:error, {:unplanned_lifecycle_cell, %{cell_id: "other", sequence: 2}}} =
             Tracker.reserve_result(tracker, unknown)

    assert {:ok, reservation} = Tracker.reserve_result(tracker, result())
    assert Tracker.projection(tracker).completed == []

    assert {:error, {:invalid_lifecycle_transition, "cell", :already_reserved}} =
             Tracker.reserve_result(tracker, result())

    assert :ok = Tracker.commit_result(tracker, reservation)
    assert Tracker.projection(tracker).completed == [%{cell_id: "cell", sequence: 1}]

    assert {:error, {:invalid_lifecycle_transition, "cell", :already_completed}} =
             Tracker.reserve_result(tracker, result())
  end

  test "releases a reservation without committing completion" do
    assert {:ok, tracker} = Tracker.start(manifest(), fn -> "2026-08-12T12:00:00Z" end)
    assert {:ok, reservation} = Tracker.reserve_result(tracker, result())

    assert :ok = Tracker.release_result(tracker, reservation)
    assert Tracker.projection(tracker).completed == []
    assert {:ok, _new_reservation} = Tracker.reserve_result(tracker, result())
  end

  test "rejects stale reservations and all terminal-state transitions" do
    assert {:ok, tracker} = Tracker.start(manifest(), fn -> raise "clock failed" end)
    on_exit(fn -> if Process.alive?(tracker), do: Agent.stop(tracker) end)
    assert Tracker.projection(tracker).started_at == "unknown"

    mismatched = %{cell_id: "cell", sequence: 2}

    assert {:error, {:lifecycle_cell_mismatch, ^mismatched, %{cell_id: "cell", sequence: 1}}} =
             Tracker.started(tracker, mismatched)

    assert :ok = Tracker.started(tracker, result())

    assert {:error, {:invalid_lifecycle_transition, "cell", :already_started}} =
             Tracker.started(tracker, result())

    assert {:error, {:invalid_lifecycle_run_id, "other"}} =
             Tracker.validate_finish(tracker, %{run_id: "other", planned: 1, completed: 0})

    assert {:error, {:invalid_lifecycle_completed_count, 1, 0}} =
             Tracker.validate_finish(tracker, %{run_id: "run", planned: 1, completed: 1})

    assert {:ok, reservation} = Tracker.reserve_result(tracker, result())
    stale = %{reservation | token: make_ref()}

    assert {:error, {:invalid_lifecycle_result_reservation, "cell"}} =
             Tracker.commit_result(tracker, stale)

    assert {:error, {:invalid_lifecycle_result_reservation, "cell"}} =
             Tracker.release_result(tracker, stale)

    assert :ok = Tracker.release_result(tracker, reservation)
    assert {:error, {:missing_lifecycle_result_reservation, "cell"}} = Tracker.commit_result(tracker, reservation)
    assert {:error, {:missing_lifecycle_result_reservation, "cell"}} = Tracker.release_result(tracker, reservation)

    assert :ok = Tracker.incomplete(tracker, {:failed, [%RuntimeError{message: "failure"}]}, fn -> nil end)
    assert :ok = Tracker.finalization_error(tracker, :manifest, {:write, :failed})
    assert Tracker.projection(tracker).finished_at == "unknown"

    assert {:error, {:invalid_lifecycle_transition, :incomplete, :finish}} =
             Tracker.validate_finish(tracker, %{run_id: "run", planned: 1, completed: 0})

    assert {:error, {:invalid_lifecycle_transition, :incomplete, :start}} = Tracker.started(tracker, result())

    assert {:error, {:invalid_lifecycle_transition, :incomplete, :reserve_result}} =
             Tracker.reserve_result(tracker, result())

    assert {:error, {:invalid_lifecycle_transition, :incomplete, :commit_result}} =
             Tracker.commit_result(tracker, reservation)

    assert {:error, {:invalid_lifecycle_transition, :incomplete, :release_result}} =
             Tracker.release_result(tracker, reservation)
  end

  defp manifest do
    %{
      run_id: "run",
      suite_id: "suite",
      cells: [%{cell_id: "cell", sequence: 1}]
    }
  end

  defp result do
    %{
      cell_id: "cell",
      sequence: 1,
      execution: %{status: :ok},
      evaluation: %{status: :passed}
    }
  end
end
