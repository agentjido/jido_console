defmodule Jido.Console.Automation.JSONLTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Automation.{Contract, JSONL}

  setup do
    root = Path.join(System.tmp_dir!(), "jido-cli-jsonl-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "writes to a selected output device without a file directory" do
    {:ok, device} = StringIO.open("")
    assert {:ok, sink} = JSONL.open(manifest(), nil, output_device: device)
    assert :ok = JSONL.emit(sink, result("agent"))
    assert :ok = JSONL.finish(sink, summary())
    {_input, output} = StringIO.contents(device)
    assert [line] = String.split(output, "\n", trim: true)
    decoded = Jason.decode!(line)
    assert decoded["schema"] == "jido.case-result"
    assert decoded["execution_environment"] == %{"status" => "not_requested"}
  end

  test "accepts an empty directory and rejects unsafe output targets", %{root: root} do
    empty = Path.join(root, "empty")
    File.mkdir_p!(empty)
    {:ok, device} = StringIO.open("")

    assert {:ok, sink} = JSONL.open(manifest(), empty, output_device: device)
    assert File.regular?(Path.join(empty, "manifest.json"))
    assert File.regular?(Path.join(empty, "lifecycle.json"))
    assert :ok = JSONL.started(sink, %{cell_id: "cell", sequence: 1})
    assert :ok = JSONL.emit(sink, result("agent"))
    assert :ok = JSONL.finish(sink, summary())

    lifecycle = empty |> Path.join("lifecycle.json") |> File.read!() |> Jason.decode!()
    assert lifecycle["status"] == "completed"
    assert lifecycle["completed"] == [%{"cell_id" => "cell", "sequence" => 1}]
    assert lifecycle["missing"] == []

    assert {:error, {:invalid_output_directory, 42}} = JSONL.open(manifest(), 42)

    blocked = Path.join(root, "blocked")
    File.mkdir_p!(blocked)
    File.write!(Path.join(blocked, "keep"), "data")

    assert {:error, {:output_directory_not_empty, ^blocked, ["keep"]}} =
             JSONL.open(manifest(), blocked)

    file = Path.join(root, "file")
    File.write!(file, "data")

    assert {:error, {:output_directory_unavailable, ^file, :enotdir}} =
             JSONL.open(manifest(), file)
  end

  test "validates a manifest before it creates an output directory", %{root: root} do
    output = Path.join(root, "not-created")

    assert {:error, {:invalid_automation_contract, :manifest, _errors}} =
             JSONL.open(%{schema: "jido.run-manifest"}, output)

    refute File.exists?(output)
  end

  test "rejects malformed records and summaries before write" do
    {:ok, device} = StringIO.open("")
    assert {:ok, sink} = JSONL.open(manifest(), nil, output_device: device)

    assert {:error, {:invalid_automation_contract, :case_result, _errors}} =
             JSONL.emit(sink, %{schema: "jido.case-result"})

    assert {:error, {:invalid_automation_contract, :summary, _errors}} =
             JSONL.finish(sink, %{schema: "jido.run-summary"})

    assert {_input, ""} = StringIO.contents(device)
  end

  test "reads manifest and summary JSON with unknown optional fields" do
    decoded_manifest = json_round_trip(manifest()) |> Map.put("future_field", %{})
    decoded_summary = json_round_trip(summary()) |> Map.put("future_field", %{})
    decoded_lifecycle = lifecycle() |> json_round_trip() |> Map.put("future_field", %{})

    assert {:ok, %{schema: "jido.run-manifest"}} = Contract.read_manifest(decoded_manifest)
    assert {:ok, %{schema: "jido.run-summary"}} = Contract.read_summary(decoded_summary)
    assert {:ok, %{schema: "jido.run-lifecycle"}} = Contract.read_lifecycle(decoded_lifecycle)
  end

  test "keeps explicit agent keys inside the output directory", %{root: root} do
    output = Path.join(root, "artifacts")
    {:ok, device} = StringIO.open("")
    assert {:ok, sink} = JSONL.open(manifest(), output, output_device: device)
    assert :ok = JSONL.emit(sink, result("../../Outside Agent"))

    assert [path] = Path.wildcard(Path.join(output, "by-agent/*.jsonl"))
    assert Path.dirname(path) == Path.join(output, "by-agent")
    refute File.exists?(Path.join(root, "Outside Agent.jsonl"))
  end

  test "rejects an unplanned lifecycle transition", %{root: root} do
    output = Path.join(root, "transition")
    {:ok, device} = StringIO.open("")
    assert {:ok, sink} = JSONL.open(manifest(), output, output_device: device)

    assert {:error, {:unplanned_lifecycle_cell, %{cell_id: "other", sequence: 2}}} =
             JSONL.started(sink, %{cell_id: "other", sequence: 2})

    assert :ok = JSONL.abort(sink, :invalid_transition)
    lifecycle = output |> Path.join("lifecycle.json") |> File.read!() |> Jason.decode!()
    assert lifecycle["status"] == "incomplete"
    assert lifecycle["started"] == []
    assert lifecycle["missing"] == [%{"cell_id" => "cell", "sequence" => 1}]
  end

  defp result(agent_key) do
    %{
      schema: "jido.case-result",
      schema_version: 1,
      type: "case.result",
      run_id: "run",
      cell_id: "cell",
      sequence: 1,
      dimensions: %{agent_key: agent_key},
      sources: sources(),
      execution: %{
        status: :ok,
        started_at: "2026-08-12T12:00:00Z",
        duration_ms: 0,
        turn_count: 0
      },
      execution_environment: %{status: :not_requested},
      evaluation: %{status: :unscored, assertion_count: 0, failed_assertion_count: 0},
      turns: [],
      usage: %{},
      error: nil
    }
    |> put_in([:dimensions], dimensions(agent_key))
  end

  defp manifest do
    %{
      schema: "jido.run-manifest",
      schema_version: 1,
      run_id: "run",
      suite_id: "suite",
      suite_file: "suite.yml",
      suite_sha256: "suite-sha",
      versions: %{jido_console: "1", jidoka: "1", elixir: "1", otp: "1"},
      matrix: %{agents: ["agent"], models: ["model"], scenarios: ["scenario"], repeats: 1, cells: 1},
      cells: [
        %{
          sequence: 1,
          cell_id: "cell",
          dimensions: dimensions("agent"),
          sources: sources(),
          execution_environment: %{status: :not_requested}
        }
      ]
    }
  end

  defp summary do
    %{
      schema: "jido.run-summary",
      schema_version: 1,
      run_id: "run",
      suite_id: "suite",
      status: :passed,
      planned: 1,
      completed: 1,
      counts: %{passed: 1, failed: 0, errors: 0, unscored: 0},
      duration_ms: 0
    }
  end

  defp lifecycle do
    %{
      schema: "jido.run-lifecycle",
      schema_version: 1,
      run_id: "run",
      suite_id: "suite",
      status: :running,
      started_at: "2026-08-12T12:00:00Z",
      finished_at: nil,
      planned: [%{cell_id: "cell", sequence: 1}],
      started: [],
      completed: [],
      failed: [],
      cancelled: [],
      missing: [%{cell_id: "cell", sequence: 1}],
      primary_error: nil,
      finalization_errors: []
    }
  end

  defp dimensions(agent_key) do
    %{
      suite_id: "suite",
      agent_key: agent_key,
      agent_spec_id: "agent",
      scenario_id: "scenario",
      model_key: "model",
      model_ref: "openai:test",
      trial: 1
    }
  end

  defp sources do
    %{
      agent_file: "agent.yml",
      scenario_file: "scenario.yml",
      agent_sha256: "agent-sha",
      effective_agent_sha256: "effective-sha",
      scenario_sha256: "scenario-sha"
    }
  end

  defp json_round_trip(value), do: value |> Jason.encode!() |> Jason.decode!()
end
