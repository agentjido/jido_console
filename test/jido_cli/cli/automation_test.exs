defmodule Jido.Cli.AutomationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Jido.Cli.Automation
  alias Jido.Cli.Automation.Interrupt
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
        execution: %{
          status: :ok,
          started_at: "2026-08-12T12:00:00Z",
          duration_ms: 1,
          turn_count: 0
        },
        evaluation: %{status: :failed, assertion_count: 1, failed_assertion_count: 1}
      )
    end
  end

  defmodule UnscoredEngine do
    @behaviour Jido.Cli.Automation.Engine

    @impl true
    def run(cell, _opts) do
      Result.new(cell,
        execution: %{
          status: :ok,
          started_at: "2026-08-12T12:00:00Z",
          duration_ms: 1,
          turn_count: 0
        },
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

  defmodule MalformedEngine do
    @behaviour Jido.Cli.Automation.Engine

    @impl true
    def run(cell, _opts) do
      FakeEngine.run(cell, [])
      |> put_in([:execution, :duration_ms], "not-an-integer")
    end
  end

  defmodule ControlledCancellationSource do
    @behaviour Jido.Cli.Automation.Interrupt

    @impl true
    def start(owner, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:cancellation_source_ready, owner})
      {:ok, test_pid}
    end

    @impl true
    def stop(test_pid) do
      send(test_pid, :cancellation_source_stopped)
      :ok
    end
  end

  defmodule CancellableEngine do
    @behaviour Jido.Cli.Automation.Engine

    alias Jido.Cli.Automation.Result
    alias Jidoka.Cancellation

    @impl true
    def run(_cell, _opts), do: raise("cancellable engine must use its public handle")

    @impl true
    def start(cell, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      controller = spawn(fn -> loop(cell, []) end)
      send(test_pid, {:automation_cell_started, cell.cell_id})
      {:ok, %{cell: cell, controller: controller, test_pid: test_pid}}
    end

    @impl true
    def await(%{controller: controller}, _opts) do
      send(controller, {:await, self()})

      receive do
        {:engine_result, result} -> result
      after
        1_000 -> {:error, :fake_engine_await_timeout}
      end
    end

    @impl true
    def cancel(%{cell: cell, controller: controller, test_pid: test_pid}, _opts) do
      cancellation =
        Cancellation.new!(
          request_id: "fake-#{cell.cell_id}",
          cancelled_at_ms: 1
        )

      send(controller, {:cancel, self(), cancellation})
      send(test_pid, {:automation_cell_cancelled, cell.cell_id})

      receive do
        {:engine_cancelled, ^cancellation} -> {:ok, cancellation}
      after
        1_000 -> {:error, :fake_engine_cancel_timeout}
      end
    end

    defp loop(cell, awaiters) do
      receive do
        {:await, from} ->
          loop(cell, [from | awaiters])

        {:cancel, from, cancellation} ->
          result = cancelled_result(cell, cancellation)
          Enum.each(awaiters, &send(&1, {:engine_result, result}))
          send(from, {:engine_cancelled, cancellation})
          completed_loop(result)
      end
    end

    defp completed_loop(result) do
      receive do
        {:await, from} ->
          send(from, {:engine_result, result})
          :ok

        {:cancel, from, cancellation} ->
          send(from, {:engine_cancelled, cancellation})
          completed_loop(result)
      after
        1_000 -> :ok
      end
    end

    defp cancelled_result(cell, cancellation) do
      Result.new(cell,
        execution: %{
          status: :cancelled,
          started_at: "2026-08-12T12:00:00Z",
          duration_ms: 1,
          turn_count: 0
        },
        evaluation: Result.evaluation([], :cancelled),
        turns: [],
        usage: %{},
        error: Result.error(cancellation)
      )
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

  test "converts a malformed engine map into one valid execution error", %{root: root} do
    agent = Path.join(root, "agent.yml")
    input = Path.join(root, "prompt.md")
    write_agent(agent, "agent")
    File.write!(input, "Hello")

    output =
      capture_io(fn ->
        assert {:ok, summary} =
                 Automation.execute(
                   ["run", "--agent", agent, "--input", input],
                   engine: MalformedEngine,
                   run_id: "run-malformed"
                 )

        assert summary.counts.errors == 1
      end)

    assert [record] = decode_jsonl(output)
    assert record["execution"]["status"] == "error"
    assert record["error"]["message"] =~ "execution failed"
  end

  test "cancels active cells, stops admission, and records not-started cells", %{root: root} do
    write_agent(Path.join(root, "agent.yml"), "agent")
    write_scenario(Path.join(root, "scenario.yml"))
    suite_path = Path.join(root, "suite.yml")
    output = Path.join(root, "artifacts")

    File.write!(suite_path, """
    version: 1
    suite:
      id: cancelled
      agents:
        - key: agent
          file: agent.yml
      scenarios:
        - scenario.yml
      models:
        - key: declared
          source: agent
      matrix:
        repeats: 3
      run:
        jobs: 1
    """)

    {:ok, stdout} = StringIO.open("")
    {:ok, stderr} = StringIO.open("")
    test_pid = self()

    task =
      Task.async(fn ->
        Automation.execute(
          ["eval", suite_path, "--output", output],
          engine: CancellableEngine,
          cancellation_source: ControlledCancellationSource,
          test_pid: test_pid,
          output_device: stdout,
          error_device: stderr,
          run_id: "run-cancelled"
        )
      end)

    assert_receive {:cancellation_source_ready, coordinator}, 1_000
    assert_receive {:automation_cell_started, started_cell_id}, 1_000
    :ok = Interrupt.request(coordinator, :test_interrupt)
    assert_receive {:automation_cell_cancelled, ^started_cell_id}, 1_000

    assert {:ok, summary} = Task.await(task, 1_000)
    assert summary.status == :cancelled
    assert summary.planned == 3
    assert summary.completed == 1
    assert summary.counts.cancelled == 1
    assert length(summary.not_started) == 2
    refute started_cell_id in summary.not_started
    refute_receive {:automation_cell_started, _cell_id}
    assert_receive :cancellation_source_stopped

    {_input, stdout_text} = StringIO.contents(stdout)
    assert [%{"execution" => %{"status" => "cancelled"}}] = decode_jsonl(stdout_text)

    {_input, stderr_text} = StringIO.contents(stderr)
    assert stderr_text =~ "automated run cancelled"
    assert stderr_text =~ "test_interrupt"

    summary_file = output |> Path.join("summary.json") |> File.read!() |> Jason.decode!()
    assert summary_file["status"] == "cancelled"
    assert length(summary_file["not_started"]) == 2
    assert length(decode_jsonl(File.read!(Path.join(output, "results.jsonl")))) == 1
  end

  test "the signal handler forwards termination through the interrupt boundary" do
    assert {:ok, owner} = Jido.Cli.Automation.Interrupt.Signal.init(self())
    assert {:ok, ^owner} = Jido.Cli.Automation.Interrupt.Signal.handle_event(:sigterm, owner)
    assert_receive {:jido_cli_automation_cancel, :sigterm}
  end

  test "tags command and configuration errors" do
    assert {:error, :usage, {:unknown_automation_command, ["compare"]}} =
             Automation.execute(["compare"])

    assert {:error, :configuration, _reason} =
             Automation.execute(["eval", "/path/that/does/not/exist.yml"])
  end

  test "profile resolution fails before output artifacts open", %{root: root} do
    agent = Path.join(root, "profile-agent.yml")
    input = Path.join(root, "profile-input.txt")
    output = Path.join(root, "must-not-exist")

    File.write!(agent, """
    version: 1
    agent:
      id: profile_agent
      model: openai:gpt-4o-mini
      execution_profile: missing
    """)

    File.write!(input, "Hello")

    assert {:error, :configuration, {:missing_execution_profile_resolver, "missing"}} =
             Automation.execute([
               "run",
               "--agent",
               agent,
               "--input",
               input,
               "--output",
               output
             ])

    refute File.exists?(output)
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
