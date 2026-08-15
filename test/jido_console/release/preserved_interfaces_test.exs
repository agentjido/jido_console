defmodule Jido.Console.Release.PreservedInterfacesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Jido.Console.Automation.{Command, JSONL}

  test "user-facing command grammar remains jido, run, and eval" do
    help = capture_io(fn -> assert :ok = Jido.Console.run(["--help"]) end)

    assert help =~ "Usage:\n  jido\n"
    assert help =~ "jido run --agent FILE"
    assert help =~ "jido eval SUITE"
    refute help =~ "jido_cli"
    refute help =~ "Jido.Cli"
  end

  test "version output uses the jido executable name" do
    output = capture_io(fn -> assert :ok = Jido.Console.run(["--version"]) end)
    assert output == "jido #{Jido.Console.Release.Identity.version()}\n"
  end

  test "command parser still accepts the current run and eval grammar" do
    assert {:ok, %{name: :run, agent: "agent.yml", input: "prompt.md"}} =
             Command.parse(["run", "--agent", "agent.yml", "--input", "prompt.md"])

    assert {:ok, %{name: :eval, suite: "suite.yml"}} =
             Command.parse(["eval", "suite.yml"])
  end

  test "JSONL records keep the portable case-result schema" do
    {:ok, device} = StringIO.open("")
    assert {:ok, sink} = JSONL.open(manifest(), nil, output_device: device)
    assert :ok = JSONL.emit(sink, result())
    assert :ok = JSONL.finish(sink, summary())
    {_input, output} = StringIO.contents(device)
    assert [line] = String.split(output, "\n", trim: true)
    assert Jason.decode!(line)["schema"] == "jido.case-result"
  end

  test "CLI exit statuses remain 0, 1, and 64" do
    assert :ok = Jido.Console.run(["--help"])

    assert capture_io(:stderr, fn ->
             assert {:error, 1} = Jido.Console.run(["--wat"])
           end) =~ "unknown option"

    assert capture_io(:stderr, fn ->
             assert {:error, 64} = Jido.Console.run(["agent.yaml"])
           end) =~ "Usage:\n  jido"
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
          dimensions: dimensions(),
          sources: sources(),
          execution_environment: %{status: :not_requested}
        }
      ]
    }
  end

  defp result do
    %{
      schema: "jido.case-result",
      schema_version: 1,
      type: "case.result",
      run_id: "run",
      cell_id: "cell",
      sequence: 1,
      dimensions: dimensions(),
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

  defp dimensions do
    %{
      suite_id: "suite",
      agent_key: "agent",
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
end
