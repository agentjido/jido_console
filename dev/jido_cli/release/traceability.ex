defmodule Jido.Cli.Release.Traceability do
  @moduledoc "Validates the live Milestone 1 Beadwork graph without storing a second task system."

  @entry "jido_console-g0e15"
  @ids Enum.map(1..30, &"jido_console-m1e#{String.pad_leading(Integer.to_string(&1), 2, "0")}")

  @doc "Reads and validates the current Milestone 1 Beadwork graph."
  @spec run!(keyword()) :: map()
  def run!(opts \\ []) do
    project_root = opts |> Keyword.get(:project_root, File.cwd!()) |> Path.expand()
    plan = read_plan!(project_root)
    exporter = Keyword.get(opts, :export_runner, &export!/1)
    identity_reader = Keyword.get(opts, :beadwork_identity, &beadwork_identity!/1)
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    items =
      project_root
      |> exporter.()
      |> parse_export!()
      |> Enum.filter(&(get_in(&1, ["labels"]) |> List.wrap() |> Enum.member?(plan["beadwork"]["label"])))
      |> Enum.sort_by(& &1["id"])

    summary = validate!(items, plan)
    identity = identity_reader.(project_root)

    Map.merge(summary, %{
      "status" => "passed",
      "source" => %{
        "command" => "bw export",
        "uri" => plan["beadwork"]["uri"],
        "revision" => identity["revision"],
        "revision_time" => identity["revision_time"],
        "captured_at" => clock.() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "sha256" => digest(items)
      }
    })
  end

  @doc false
  @spec validate!([map()], map()) :: map()
  def validate!(items, plan) do
    ids = Enum.map(items, & &1["id"])
    ensure!(length(ids) == length(Enum.uniq(ids)), "duplicate Beadwork item ID")
    ensure!(ids == @ids, "expected 30 Milestone 1 Beadwork items")

    Enum.each(items, &validate_item!/1)

    known = MapSet.new([@entry | @ids])

    Enum.each(items, fn item ->
      case Enum.find(item["blocked_by"], &(not MapSet.member?(known, &1))) do
        nil -> :ok
        dependency -> raise "#{item["id"]} has unknown dependency #{dependency}"
      end
    end)

    order = topological_order!(items)
    critical_path = longest_path!(items, order)
    ensure!(critical_path == plan["critical_path"], "declared critical path does not match the live graph")

    %{
      "item_count" => length(items),
      "edge_count" => Enum.sum(Enum.map(items, &length(&1["blocked_by"]))),
      "critical_path" => critical_path
    }
  end

  defp validate_item!(item) do
    id = item["id"]
    labels = List.wrap(item["labels"])
    dependencies = item["blocked_by"]

    ensure!(present?(item["owner"]), "#{id} is missing owner")
    ensure!(one_label?(labels, "effort:"), "#{id} needs one effort label")
    ensure!(one_label?(labels, "readiness:"), "#{id} needs one readiness label")
    ensure!("v0.1" in labels, "#{id} is missing target release v0.1")
    ensure!(is_list(dependencies) and dependencies != [], "#{id} is missing dependencies")
    ensure!(proof_artifact?(item["description"]), "#{id} is missing a proof artifact plan")
  end

  defp topological_order!(items) do
    dependencies =
      Map.new(items, fn item ->
        internal = item["blocked_by"] |> Enum.filter(&(&1 in @ids)) |> MapSet.new()
        {item["id"], internal}
      end)

    take_ready!(dependencies, [])
  end

  defp take_ready!(dependencies, order) when map_size(dependencies) == 0, do: order

  defp take_ready!(dependencies, order) do
    ready =
      dependencies
      |> Enum.filter(fn {_id, blocked_by} -> MapSet.size(blocked_by) == 0 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    ensure!(ready != [], "Milestone 1 dependency graph contains a cycle")
    ready_set = MapSet.new(ready)

    remaining =
      dependencies
      |> Map.drop(ready)
      |> Map.new(fn {id, blocked_by} -> {id, MapSet.difference(blocked_by, ready_set)} end)

    take_ready!(remaining, order ++ ready)
  end

  defp longest_path!(items, order) do
    by_id = Map.new(items, &{&1["id"], &1})

    {_distance, predecessor} =
      Enum.reduce(order, {%{@entry => 1}, %{}}, fn id, {distance, predecessor} ->
        {score, dependency} =
          by_id[id]["blocked_by"]
          |> Enum.map(&{Map.get(distance, &1, 0), &1})
          |> Enum.sort_by(fn {value, dependency} -> {-value, dependency} end)
          |> List.first()

        ensure!(score > 0, "#{id} is not reachable from #{@entry}")
        {Map.put(distance, id, score + 1), Map.put(predecessor, id, dependency)}
      end)

    unwind("jido_console-m1e30", predecessor, [])
  end

  defp unwind(@entry, _predecessor, path), do: [@entry | path]
  defp unwind(id, predecessor, path), do: unwind(Map.fetch!(predecessor, id), predecessor, [id | path])

  defp read_plan!(project_root) do
    project_root
    |> Path.join("roadmap/milestones/01-ship-trustworthy-local-kernel/delivery-plan.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp parse_export!(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, item} when is_map(item) -> item
        _error -> raise "bw export returned invalid JSONL"
      end
    end)
  end

  defp export!(project_root) do
    case System.cmd("bw", ["export"], cd: project_root, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "bw export failed with status #{status}:\n#{output}"
    end
  end

  defp beadwork_identity!(project_root) do
    %{
      "revision" => git!(project_root, ["rev-parse", "beadwork"]),
      "revision_time" => git!(project_root, ["show", "-s", "--format=%cI", "beadwork"])
    }
  end

  defp git!(project_root, args) do
    case System.cmd("git", args, cd: project_root, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git #{Enum.join(args, " ")} failed with status #{status}: #{output}"
    end
  end

  defp proof_artifact?(description) when is_binary(description) do
    case String.split(description, "## Proof Artifacts", parts: 2) do
      [_before, section] -> Regex.match?(~r/(?:^|\n)\s*-\s+\S/, section)
      _other -> false
    end
  end

  defp proof_artifact?(_description), do: false
  defp one_label?(labels, prefix), do: Enum.count(labels, &String.starts_with?(&1, prefix)) == 1
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp ensure!(true, _message), do: :ok
  defp ensure!(false, message), do: raise(message)
  defp digest(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)
end
