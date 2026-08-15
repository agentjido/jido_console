defmodule Jido.Console.Automation.ArtifactIntegrityTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Jido.Console.Automation.JSONL

  setup do
    root = Path.join(System.tmp_dir!(), "jido-cli-artifacts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "normal finalization is atomic and gives every file a private mode", %{root: root} do
    output = Path.join(root, "normal")
    {:ok, stdout} = StringIO.open("")

    assert {:ok, sink} =
             JSONL.open(manifest(1), output,
               output_device: stdout,
               utc_now: fn -> "2026-08-12T12:00:00Z" end
             )

    assert lifecycle(output)["status"] == "running"
    assert :ok = JSONL.started(sink, cell_ref(1))
    assert :ok = JSONL.emit(sink, result(1, :ok))
    assert :ok = JSONL.finish(sink, summary(1, 1, :passed))

    terminal = lifecycle(output)
    assert terminal["status"] == "completed"
    assert terminal["completed"] == [json_cell_ref(1)]
    assert terminal["failed"] == []
    assert terminal["missing"] == []
    assert terminal["finished_at"] == "2026-08-12T12:00:00Z"

    for relative <- [
          "manifest.json",
          "lifecycle.json",
          "summary.json",
          "results.jsonl",
          "by-agent/agent.jsonl"
        ] do
      stat = File.stat!(Path.join(output, relative))
      assert (stat.mode &&& 0o777) == 0o600
    end

    assert Path.wildcard(Path.join(output, "**/.*.tmp")) == []
    assert [_record] = jsonl(output, "results.jsonl")
    assert [_record] = jsonl(output, "by-agent/agent.jsonl")
  end

  test "an initial manifest failure leaves an explicit incomplete marker", %{root: root} do
    output = Path.join(root, "manifest-failure")
    artifact_io = failing_io({:write, ".manifest.json.tmp"})

    assert {:error, {:automation_artifact_write_failed, :manifest, :injected_failure}} =
             JSONL.open(manifest(1), output, artifact_io: artifact_io)

    refute File.exists?(Path.join(output, "manifest.json"))
    refute File.exists?(Path.join(output, ".manifest.json.tmp"))

    terminal = lifecycle(output)
    assert terminal["status"] == "incomplete"
    assert terminal["primary_error"] == nil
    assert [%{"phase" => "initialization"}] = terminal["finalization_errors"]
    assert terminal["missing"] == [json_cell_ref(1)]
  end

  test "a stdout failure keeps complete file records and marks the run incomplete", %{root: root} do
    output = Path.join(root, "stdout-failure")
    {:ok, stdout} = StringIO.open("")
    {:ok, writes} = Agent.start_link(fn -> 0 end)

    writer = fn _device, _line ->
      Agent.update(writes, &(&1 + 1))
      {:error, :closed}
    end

    assert {:ok, sink} =
             JSONL.open(manifest(2), output, output_device: stdout, output_writer: writer)

    assert :ok = JSONL.started(sink, cell_ref(1))

    assert {:error, {:automation_artifact_write_failed, :stdout, :closed}} =
             JSONL.emit(sink, result(1, :ok))

    assert :ok = JSONL.abort(sink, {:stdout_unavailable, "private-token-value"})
    assert Agent.get(writes, & &1) == 1
    assert {_input, ""} = StringIO.contents(stdout)
    assert [_record] = jsonl(output, "results.jsonl")
    assert [_record] = jsonl(output, "by-agent/agent.jsonl")

    terminal = lifecycle(output)
    assert terminal["status"] == "incomplete"
    assert terminal["completed"] == [json_cell_ref(1)]
    assert terminal["missing"] == [json_cell_ref(2)]
    assert is_map(terminal["primary_error"])
    assert [%{"phase" => "stdout"}] = terminal["finalization_errors"]
    refute File.read!(Path.join(output, "lifecycle.json")) =~ "private-token-value"
  end

  test "a results-file failure writes no line to any output", %{root: root} do
    output = Path.join(root, "results-failure")
    {:ok, stdout} = StringIO.open("")
    artifact_io = failing_io({:write, ".results.jsonl.tmp"})

    assert {:ok, sink} =
             JSONL.open(manifest(1), output,
               output_device: stdout,
               artifact_io: artifact_io
             )

    assert :ok = JSONL.started(sink, cell_ref(1))

    assert {:error, {:automation_artifact_write_failed, :results, :injected_failure}} =
             JSONL.emit(sink, result(1, :ok))

    assert :ok = JSONL.abort(sink, :result_artifact_failed)
    refute File.exists?(Path.join(output, "results.jsonl"))
    refute File.exists?(Path.join(output, "by-agent/agent.jsonl"))
    refute File.exists?(Path.join(output, ".results.jsonl.tmp"))
    assert {_input, ""} = StringIO.contents(stdout)

    terminal = lifecycle(output)
    assert terminal["status"] == "incomplete"
    assert terminal["completed"] == []
    assert terminal["missing"] == [json_cell_ref(1)]
  end

  test "a temporary-file cleanup failure is preserved with the write failure", %{root: root} do
    output = Path.join(root, "cleanup-failure")
    {:ok, stdout} = StringIO.open("")

    artifact_io =
      failing_io([
        {:write, ".results.jsonl.tmp", :injected_write_failure},
        {:rm, ".results.jsonl.tmp", :injected_cleanup_failure}
      ])

    assert {:ok, sink} =
             JSONL.open(manifest(1), output,
               output_device: stdout,
               artifact_io: artifact_io
             )

    assert :ok = JSONL.started(sink, cell_ref(1))

    assert {:error,
            {:automation_artifact_write_failed, :results,
             {:artifact_write_and_cleanup_failed, :injected_write_failure, :injected_cleanup_failure}}} =
             JSONL.emit(sink, result(1, :ok))

    assert :ok = JSONL.abort(sink, :artifact_failed)
    [error] = lifecycle(output)["finalization_errors"]
    assert "injected_write_failure" in error["details"]["codes"]
    assert "injected_cleanup_failure" in error["details"]["codes"]
  end

  test "a per-agent failure preserves the complete aggregate record", %{root: root} do
    output = Path.join(root, "agent-failure")
    {:ok, stdout} = StringIO.open("")
    artifact_io = failing_io({:write, ".agent.jsonl.tmp"})

    assert {:ok, sink} =
             JSONL.open(manifest(1), output,
               output_device: stdout,
               artifact_io: artifact_io
             )

    assert :ok = JSONL.started(sink, cell_ref(1))

    assert {:error, {:automation_artifact_write_failed, :by_agent, :injected_failure}} =
             JSONL.emit(sink, result(1, :ok))

    assert :ok = JSONL.abort(sink, :agent_artifact_failed)
    assert [_record] = jsonl(output, "results.jsonl")
    refute File.exists?(Path.join(output, "by-agent/agent.jsonl"))
    assert {_input, ""} = StringIO.contents(stdout)

    terminal = lifecycle(output)
    assert terminal["status"] == "incomplete"
    assert terminal["completed"] == []
    assert terminal["missing"] == [json_cell_ref(1)]
    assert [%{"phase" => "by_agent"}] = terminal["finalization_errors"]
  end

  test "a summary rename failure keeps results and writes an incomplete marker", %{root: root} do
    output = Path.join(root, "summary-failure")
    {:ok, stdout} = StringIO.open("")
    artifact_io = failing_io({:rename, "summary.json"})

    assert {:ok, sink} =
             JSONL.open(manifest(1), output,
               output_device: stdout,
               artifact_io: artifact_io
             )

    assert :ok = JSONL.started(sink, cell_ref(1))
    assert :ok = JSONL.emit(sink, result(1, :ok))

    assert {:error, {:automation_artifact_finalization_failed, :summary, _reason}} =
             JSONL.finish(sink, summary(1, 1, :passed))

    refute File.exists?(Path.join(output, "summary.json"))
    refute File.exists?(Path.join(output, ".summary.json.tmp"))
    assert [_record] = jsonl(output, "results.jsonl")

    terminal = lifecycle(output)
    assert terminal["status"] == "incomplete"
    assert terminal["completed"] == [json_cell_ref(1)]
    assert terminal["missing"] == []
    assert terminal["primary_error"] == nil
    assert [%{"phase" => "summary"}] = terminal["finalization_errors"]
  end

  defp failing_io({operation, suffix}),
    do: failing_io([{operation, suffix, :injected_failure}])

  defp failing_io(faults) when is_list(faults) do
    {:ok, remaining} = Agent.start_link(fn -> Map.new(faults, &{&1, 1}) end)

    failure = fn current_operation, path -> injected_failure(remaining, faults, current_operation, path) end

    %{
      write: fn path, data, modes ->
        case failure.(:write, path) do
          nil -> File.write(path, data, modes)
          reason -> {:error, reason}
        end
      end,
      rename: fn source, destination ->
        case failure.(:rename, destination) do
          nil -> File.rename(source, destination)
          reason -> {:error, reason}
        end
      end,
      rm: fn path ->
        case failure.(:rm, path) do
          nil -> File.rm(path)
          reason -> {:error, reason}
        end
      end
    }
  end

  defp injected_failure(remaining, faults, current_operation, path) do
    Enum.find_value(faults, fn {operation, suffix, _reason} = fault ->
      if current_operation == operation and String.ends_with?(path, suffix),
        do: consume_failure(remaining, fault)
    end)
  end

  defp consume_failure(remaining, {_operation, _suffix, reason} = fault) do
    Agent.get_and_update(remaining, fn values ->
      case Map.fetch!(values, fault) do
        value when value > 0 -> {reason, Map.put(values, fault, value - 1)}
        _value -> {nil, values}
      end
    end)
  end

  defp lifecycle(output) do
    output
    |> Path.join("lifecycle.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp jsonl(output, relative) do
    output
    |> Path.join(relative)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp manifest(count) do
    %{
      schema: "jido.run-manifest",
      schema_version: 1,
      run_id: "run",
      suite_id: "suite",
      suite_file: "suite.yml",
      suite_sha256: "suite-sha",
      versions: %{jido_console: "1", jidoka: "1", elixir: "1", otp: "1"},
      matrix: %{
        agents: ["agent"],
        models: ["model"],
        scenarios: ["scenario"],
        repeats: count,
        cells: count
      },
      cells: Enum.map(1..count, &manifest_cell/1)
    }
  end

  defp manifest_cell(sequence) do
    %{
      sequence: sequence,
      cell_id: "cell-#{sequence}",
      dimensions: dimensions(sequence),
      sources: sources(),
      execution_environment: %{status: :not_requested}
    }
  end

  defp result(sequence, status) do
    evaluation = if status == :ok, do: :passed, else: :not_run

    %{
      schema: "jido.case-result",
      schema_version: 1,
      type: "case.result",
      run_id: "run",
      cell_id: "cell-#{sequence}",
      sequence: sequence,
      dimensions: dimensions(sequence),
      sources: sources(),
      execution: %{
        status: status,
        started_at: "2026-08-12T12:00:00Z",
        duration_ms: 1,
        turn_count: 0
      },
      execution_environment: %{status: :not_requested},
      evaluation: %{status: evaluation, assertion_count: 0, failed_assertion_count: 0},
      turns: [],
      usage: %{},
      error: nil
    }
  end

  defp summary(planned, completed, status) do
    %{
      schema: "jido.run-summary",
      schema_version: 1,
      run_id: "run",
      suite_id: "suite",
      status: status,
      planned: planned,
      completed: completed,
      counts: %{passed: completed, failed: 0, errors: 0, unscored: 0, cancelled: 0},
      duration_ms: 1,
      not_started: []
    }
  end

  defp dimensions(sequence) do
    %{
      suite_id: "suite",
      agent_key: "agent",
      agent_spec_id: "agent",
      scenario_id: "scenario",
      model_key: "model",
      model_ref: "openai:test",
      trial: sequence
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

  defp cell_ref(sequence), do: %{cell_id: "cell-#{sequence}", sequence: sequence}
  defp json_cell_ref(sequence), do: %{"cell_id" => "cell-#{sequence}", "sequence" => sequence}
end
