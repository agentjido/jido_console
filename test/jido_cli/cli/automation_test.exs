defmodule Jido.Cli.AutomationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Jido.Cli.Automation
  alias Jido.Cli.Automation.Result

  defmodule FakeEngine do
    @behaviour Jido.Cli.Automation.Engine

    @impl true
    def run(cell, _opts) do
      Result.new(cell,
        execution: %{
          status: :ok,
          started_at: "2026-08-12T12:00:00Z",
          duration_ms: cell.sequence,
          turn_count: 1
        },
        evaluation: %{status: :passed, assertion_count: 1, failed_assertion_count: 0},
        turns: [],
        usage: %{total_tokens: 10},
        error: nil
      )
    end
  end

  defmodule FailedEngine do
    @behaviour Jido.Cli.Automation.Engine

    @impl true
    def run(cell, _opts) do
      Result.new(cell,
        execution: %{status: :ok, started_at: "2026-08-12T12:00:00Z", duration_ms: 1},
        evaluation: %{status: :failed, assertion_count: 1, failed_assertion_count: 1}
      )
    end
  end

  defmodule UnscoredEngine do
    @behaviour Jido.Cli.Automation.Engine

    @impl true
    def run(cell, _opts) do
      Result.new(cell,
        execution: %{status: :ok, started_at: "2026-08-12T12:00:00Z", duration_ms: 1},
        evaluation: %{status: :unscored, assertion_count: 0, failed_assertion_count: 0}
      )
    end
  end

  defmodule InvalidEngine do
    @behaviour Jido.Cli.Automation.Engine

    @impl true
    def run(_cell, opts) do
      case Keyword.fetch!(opts, :engine_failure) do
        :return -> :invalid
        :raise -> raise "engine failed"
        :throw -> throw(:engine_failed)
        :exit -> exit(:engine_failed)
      end
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "jido-cli-automation-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "runs a suite, writes JSONL, and creates per-agent artifacts", %{root: root} do
    write_agent(Path.join(root, "a.yml"), "agent_a")
    write_agent(Path.join(root, "b.yml"), "agent_b")
    write_scenario(Path.join(root, "scenario.yml"))
    suite_path = Path.join(root, "suite.yml")
    output = Path.join(root, "artifacts")

    File.write!(suite_path, """
    version: 1
    suite:
      id: smoke
      agents:
        - key: a
          file: a.yml
        - key: b
          file: b.yml
      scenarios:
        - scenario.yml
      models:
        - key: declared
          source: agent
        - key: pinned
          ref: openai:gpt-4o-mini
      run:
        jobs: 2
    """)

    stdout =
      capture_io(fn ->
        assert {:ok, summary} =
                 Automation.execute(
                   ["eval", suite_path, "--output", output],
                   engine: FakeEngine,
                   run_id: "run-fixed"
                 )

        assert summary.status == :passed
        assert summary.completed == 4
      end)

    records = decode_jsonl(stdout)
    assert length(records) == 4
    assert Enum.all?(records, &(&1["schema"] == "jido.case-result"))
    assert File.regular?(Path.join(output, "manifest.json"))
    assert File.regular?(Path.join(output, "summary.json"))
    assert length(decode_jsonl(File.read!(Path.join(output, "results.jsonl")))) == 4
    assert length(decode_jsonl(File.read!(Path.join(output, "by-agent/a.jsonl")))) == 2
    assert length(decode_jsonl(File.read!(Path.join(output, "by-agent/b.jsonl")))) == 2
  end

  test "runs one prompt file without a scenario file", %{root: root} do
    agent = Path.join(root, "agent.yml")
    input = Path.join(root, "prompt.md")
    write_agent(agent, "agent")
    File.write!(input, "Hello from a file.\n")

    stdout =
      capture_io(fn ->
        assert {:ok, %{status: :passed, completed: 1}} =
                 Automation.execute(
                   ["run", "--agent", agent, "--input", input],
                   engine: FakeEngine,
                   run_id: "run-fixed"
                 )
      end)

    assert [%{"dimensions" => %{"scenario_id" => "prompt"}}] = decode_jsonl(stdout)
  end

  test "rejects a nonempty output directory before execution", %{root: root} do
    agent = Path.join(root, "agent.yml")
    input = Path.join(root, "prompt.md")
    output = Path.join(root, "artifacts")
    write_agent(agent, "agent")
    File.write!(input, "Hello")
    File.mkdir_p!(output)
    File.write!(Path.join(output, "existing.txt"), "keep")

    assert {:error, :configuration, {:output_directory_not_empty, ^output, _entries}} =
             Automation.execute(
               ["run", "--agent", agent, "--input", input, "--output", output],
               engine: FakeEngine,
               run_id: "run-fixed"
             )

    assert File.read!(Path.join(output, "existing.txt")) == "keep"
  end

  test "runs a scenario with a model override", %{root: root} do
    agent = Path.join(root, "agent.yml")
    scenario = Path.join(root, "scenario.yml")
    write_agent(agent, "agent")
    write_scenario(scenario)

    stdout =
      capture_io(fn ->
        assert {:ok, %{status: :passed}} =
                 Automation.execute(
                   [
                     "run",
                     "--agent",
                     agent,
                     "--scenario",
                     scenario,
                     "--model",
                     "openai:gpt-4o-mini"
                   ],
                   engine: FakeEngine,
                   run_id: "run-fixed"
                 )
      end)

    assert [%{"dimensions" => dimensions}] = decode_jsonl(stdout)
    assert dimensions["model_key"] == "override"
  end

  test "counts failed and unscored cells", %{root: root} do
    agent = Path.join(root, "agent.yml")
    input = Path.join(root, "prompt.md")
    write_agent(agent, "agent")
    File.write!(input, "Hello")

    assert capture_summary(agent, input, FailedEngine).counts.failed == 1
    assert capture_summary(agent, input, UnscoredEngine).counts.unscored == 1
  end

  test "converts invalid engine behavior into error records", %{root: root} do
    agent = Path.join(root, "agent.yml")
    input = Path.join(root, "prompt.md")
    write_agent(agent, "agent")
    File.write!(input, "Hello")

    for failure <- [:return, :raise, :throw, :exit] do
      output =
        capture_io(fn ->
          assert {:ok, summary} =
                   Automation.execute(
                     ["run", "--agent", agent, "--input", input],
                     engine: InvalidEngine,
                     engine_failure: failure,
                     run_id: "run-#{failure}"
                   )

          assert summary.status == :failed
          assert summary.counts.errors == 1
        end)

      assert [%{"execution" => %{"status" => "error"}, "error" => error}] =
               decode_jsonl(output)

      assert is_binary(error["message"])
    end
  end

  test "tags command and configuration errors" do
    assert {:error, :usage, {:unknown_automation_command, ["compare"]}} =
             Automation.execute(["compare"])

    assert {:error, :configuration, _reason} =
             Automation.execute(["eval", "/path/that/does/not/exist.yml"])
  end

  defp decode_jsonl(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp capture_summary(agent, input, engine) do
    capture_io(fn ->
      send(
        self(),
        {:summary,
         Automation.execute(
           ["run", "--agent", agent, "--input", input],
           engine: engine,
           run_id: "run-fixed"
         )}
      )
    end)

    assert_received {:summary, {:ok, summary}}
    summary
  end

  defp write_agent(path, id) do
    File.write!(path, """
    version: 1
    agent:
      id: #{id}
      model: openai:gpt-4o-mini
      instructions: Answer briefly.
    """)
  end

  defp write_scenario(path) do
    File.write!(path, """
    version: 1
    scenario:
      id: hello
      request:
        input:
          text: Hello
      assertions:
        contains: Hello
    """)
  end
end
