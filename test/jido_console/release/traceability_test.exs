defmodule Jido.Console.Release.TraceabilityTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.Traceability

  test "validates a live export and records only its identity" do
    items = valid_items()
    export = Enum.map_join(items, "\n", &Jason.encode!/1)
    revision = String.duplicate("a", 40)
    now = ~U[2026-08-15 12:00:00Z]

    assert %{
             "status" => "passed",
             "item_count" => 30,
             "source" => %{
               "command" => "bw export",
               "revision" => ^revision,
               "captured_at" => "2026-08-15T12:00:00Z",
               "sha256" => digest
             }
           } =
             Traceability.run!(
               export_runner: fn _root -> export end,
               beadwork_identity: fn _root ->
                 %{"revision" => revision, "revision_time" => "2026-08-14T17:30:15-05:00"}
               end,
               clock: fn -> now end
             )

    assert byte_size(digest) == 64
  end

  test "rejects a missing required field" do
    items = List.update_at(valid_items(), 0, &Map.put(&1, "owner", ""))

    assert_raise RuntimeError, ~r/jido_console-m1e01 is missing owner/, fn ->
      Traceability.validate!(items, plan())
    end
  end

  test "rejects a dependency cycle" do
    items = List.update_at(valid_items(), 0, &Map.put(&1, "blocked_by", ["jido_console-m1e30"]))

    assert_raise RuntimeError, ~r/contains a cycle/, fn ->
      Traceability.validate!(items, plan())
    end
  end

  defp valid_items do
    path = plan()["critical_path"]
    predecessor = path |> Enum.chunk_every(2, 1, :discard) |> Map.new(fn [from, to] -> {to, from} end)

    Enum.map(1..30, fn number ->
      id = "jido_console-m1e#{number |> Integer.to_string() |> String.pad_leading(2, "0")}"

      %{
        "id" => id,
        "owner" => "Release owner",
        "labels" => ["effort:medium", "milestone-1", "readiness:planned", "v0.1"],
        "blocked_by" => [Map.get(predecessor, id, "jido_console-g0e15")],
        "description" => "## Proof Artifacts\n\n- #{id} result\n"
      }
    end)
  end

  defp plan do
    "roadmap/milestones/01-ship-trustworthy-local-kernel/delivery-plan.json"
    |> File.read!()
    |> Jason.decode!()
  end
end
