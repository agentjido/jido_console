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
