defmodule Jido.Console.Automation.LimitsTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Automation.Engine.Jidoka, as: JidokaEngine
  alias Jido.Console.Automation.{Coordinator, JSONL, Limits, Result}
  alias Jidoka.Agent.Spec
  alias Jidoka.Runtime.Capabilities

  defmodule ProbeEngine do
    @behaviour Jido.Console.Automation.Engine

    @impl true
    def start(cell, opts), do: {:ok, {cell, opts}}

    @impl true
    def await({cell, opts}, _await_opts) do
      owner = Keyword.fetch!(opts, :test_pid)
      provider = Limits.provider_key(cell)
      send(owner, {:limit_cell_started, provider, cell.cell_id, self()})

      receive do
        :finish_limit_cell -> :ok
      after
        2_000 -> raise "limit test did not release cell"
      end

      Result.new(cell,
        execution: %{
          status: :ok,
          started_at: "2026-08-12T12:00:00Z",
          duration_ms: 1,
          turn_count: 1
        },
        evaluation: %{status: :passed, assertion_count: 1, failed_assertion_count: 0},
        turns: [],
        usage: %{total_tokens: 10, total_cost: 0.1},
        error: nil
      )
    end

    @impl true
    def cancel(_request, _opts), do: {:error, :request_already_finished}
  end

  defmodule UsageEngine do
    @behaviour Jido.Console.Automation.Engine

    @impl true
    def start(cell, opts), do: {:ok, {cell, opts}}

    @impl true
    def await({cell, _opts}, _await_opts) do
      Result.new(cell,
        execution: %{
          status: :ok,
          started_at: "2026-08-12T12:00:00Z",
          duration_ms: 1,
          turn_count: 1
        },
        evaluation: %{status: :passed, assertion_count: 1, failed_assertion_count: 0},
        turns: [],
        usage: %{total_tokens: 10, total_cost: 0.1},
        error: nil
      )
    end

    @impl true
    def cancel(_request, _opts), do: {:error, :request_already_finished}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "jido-cli-limits-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "rejects an oversized matrix and a ceiling escalation before artifacts", %{root: root} do
    suite = write_suite(root, repeats: 3, limits: "max_cells: 2")
    output = Path.join(root, "oversized-output")

    assert {:error, :configuration, {:automation_matrix_limit_exceeded, 3, 2}} =
             Jido.Console.Automation.execute(["eval", suite, "--output", output])

    refute File.exists?(output)

    raised = write_suite(root, name: "raised.yml", repeats: 1, limits: "max_cells: 3")
    raised_output = Path.join(root, "raised-output")

    assert {:error, :configuration, {:automation_limit_exceeds_ceiling, :max_cells, 3, 2}} =
             Jido.Console.Automation.execute(["eval", raised, "--output", raised_output],
               automation_limit_ceiling: %{max_cells: 2}
             )

    refute File.exists?(raised_output)
  end

  test "provider admission respects each applied concurrency with deterministic order" do
    limits = limits(%{"openai" => 1, "anthropic" => 2}, max_total_tokens: 1_000)

    cells = [
      cell(1, "openai:model", limits),
      cell(2, "openai:model", limits),
      cell(3, "anthropic:model", limits),
      cell(4, "anthropic:model", limits)
    ]

    {:ok, output} = StringIO.open("")
    {:ok, sink} = JSONL.open(manifest(cells), nil, output_device: output)
    owner = self()

    task =
      Task.async(fn ->
        Coordinator.run(cells, sink, ProbeEngine, 3,
          automation_limits: limits,
          test_pid: owner
        )
      end)

    started = receive_started(3)
    assert Enum.map(started, &elem(&1, 0)) |> Enum.sort() == ["anthropic", "anthropic", "openai"]
    assert Enum.count(started, &(elem(&1, 0) == "openai")) == 1

    {_, _, first_pid} = Enum.find(started, &(elem(&1, 0) == "openai"))
    send(first_pid, :finish_limit_cell)
    assert_receive {:limit_cell_started, "openai", _, fourth_pid}, 1_000

    Enum.each(started, fn {_provider, _id, pid} -> send(pid, :finish_limit_cell) end)
    send(fourth_pid, :finish_limit_cell)

    assert {:ok, %{results: results, limit_stop: nil, not_started: []}} = Task.await(task, 2_000)
    assert length(results) == 4
  end

  test "invalid limits and provider escalation fail closed" do
    suite = %{
      jobs: 2,
      repeats: 1,
      limits: %{cell_timeout_ms: 0},
      scenarios: [%{turns: [%{id: "one"}]}]
    }

    assert {:error, {:invalid_automation_limit, :cell_timeout_ms, 0}} = Limits.resolve(suite, 1, [])

    assert {:error, {:unknown_automation_limit_keys, :requested, [:raw_command]}} =
             Limits.resolve(%{suite | limits: %{raw_command: "run"}}, 1, [])

    assert {:error, {:provider_concurrency_exceeds_ceiling, "openai", 2, 1}} =
             Limits.resolve(%{suite | limits: %{provider_concurrency: %{"openai" => 2}}}, 1,
               automation_limit_ceiling: %{provider_concurrency: %{"openai" => 1}}
             )
  end

  test "a suite usage budget stops later admission and preserves completed results" do
    limits = limits(%{"*" => 1}, max_total_tokens: 15)
    cells = Enum.map(1..3, &cell(&1, "openai:model", limits))
    {:ok, output} = StringIO.open("")
    {:ok, sink} = JSONL.open(manifest(cells), nil, output_device: output)
    {:ok, errors} = StringIO.open("")
    owner = self()

    task =
      Task.async(fn ->
        Coordinator.run(cells, sink, ProbeEngine, 1,
          automation_limits: limits,
          test_pid: owner,
          error_device: errors
        )
      end)

    assert_receive {:limit_cell_started, "openai", _, first}, 1_000
    send(first, :finish_limit_cell)
    assert_receive {:limit_cell_started, "openai", _, second}, 1_000
    send(second, :finish_limit_cell)

    assert {:ok,
            %{
              results: [_, _],
              limit_stop: %{kind: :total_tokens, limit: 15, observed: 20},
              not_started: [%{sequence: 3}]
            }} = Task.await(task, 2_000)
  end

  test "a limit stop finalizes completed and missing cells", %{root: root} do
    suite = write_suite(root, repeats: 3, limits: "max_total_tokens: 15")
    output = Path.join(root, "limited-output")
    {:ok, stdout} = StringIO.open("")
    {:ok, stderr} = StringIO.open("")

    assert {:ok, summary} =
             Jido.Console.Automation.execute(["eval", suite, "--output", output],
               engine: UsageEngine,
               output_device: stdout,
               error_device: stderr,
               run_id: "limited-run"
             )

    assert summary.status == :failed
    assert summary.completed == 2
    assert length(summary.not_started) == 1

    lifecycle = output |> Path.join("lifecycle.json") |> File.read!() |> Jason.decode!()
    assert lifecycle["status"] == "failed"
    assert length(lifecycle["completed"]) == 2
    assert length(lifecycle["missing"]) == 1
    assert length(lifecycle["planned"]) == 3
  end

  test "a suite deadline stops later admission without cancelling active work" do
    limits = limits(%{"*" => 1}, max_total_tokens: 1_000, suite_timeout_ms: 10)
    cells = Enum.map(1..2, &cell(&1, "openai:model", limits))
    {:ok, output} = StringIO.open("")
    {:ok, errors} = StringIO.open("")
    {:ok, sink} = JSONL.open(manifest(cells), nil, output_device: output)
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    owner = self()

    now = fn ->
      value = Agent.get(clock, & &1)
      if value == 11, do: send(owner, :deadline_clock_read)
      value
    end

    task =
      Task.async(fn ->
        Coordinator.run(cells, sink, ProbeEngine, 1,
          automation_limits: limits,
          test_pid: owner,
          error_device: errors,
          monotonic_ms: now
        )
      end)

    assert_receive {:limit_cell_started, "openai", _, first}, 1_000
    Agent.update(clock, fn _value -> 11 end)
    assert_receive :deadline_clock_read, 1_000
    assert_receive :deadline_clock_read, 1_000
    send(first, :finish_limit_cell)

    assert {:ok,
            %{
              results: [_],
              limit_stop: %{kind: :suite_timeout, limit: 10, observed: 11},
              not_started: [%{sequence: 2}]
            }} = Task.await(task, 2_000)

    refute_receive {:limit_cell_started, _, _, _}
  end

  test "the Jidoka engine projects exact sequence usage-limit evidence" do
    limits = limits(%{"*" => 1}, max_total_tokens: 5, cell_timeout_ms: 5_000)

    capabilities =
      Capabilities.new!(
        llm: fn _intent, _journal, _context ->
          {:ok,
           %{
             type: :final,
             content: "first",
             metadata: %{usage: %{input_tokens: 4, output_tokens: 3, total_tokens: 7}}
           }}
        end
      )

    result =
      cell(1, "openai:model", limits)
      |> Map.put(:runtime_opts, capabilities: capabilities)
      |> Map.put(:scenario, %{
        turns: [
          %{id: "one", input: "one", context: %{}, assertions: %{}},
          %{id: "never", input: "never", context: %{}, assertions: %{}}
        ]
      })
      |> run_jidoka([])

    assert result.execution.status == :error
    assert result.execution.turn_count == 1
    assert result.runtime_limits.status == :exceeded
    assert result.runtime_limits.exceeded == %{kind: :total_tokens, limit: 5, observed: 7}
    assert result.runtime_limits.observed.total_tokens == 7
    assert result.runtime_limits.applied.max_turns_per_cell == 8
    assert result.runtime_limits.applied.cell_timeout_ms == 5_000
  end

  defp receive_started(count) do
    Enum.map(1..count, fn _index ->
      receive do
        {:limit_cell_started, provider, id, pid} -> {provider, id, pid}
      after
        1_000 -> flunk("expected admitted cell")
      end
    end)
  end

  defp run_jidoka(cell, opts),
    do: Jido.Console.Automation.Engine.run(JidokaEngine, cell, opts)

  defp limits(providers, overrides) do
    applied =
      %{
        max_cells: 100,
        max_turns_per_cell: 10,
        cell_timeout_ms: 1_000,
        suite_timeout_ms: 10_000,
        max_total_tokens: 1_000,
        max_total_cost: 100.0,
        provider_concurrency: providers
      }
      |> Map.merge(Map.new(overrides))

    %{requested: %{}, applied: applied, cancel_active_on_stop: false}
  end

  defp cell(sequence, model_ref, limits) do
    spec = Spec.new!(id: "limit_agent", model: model_ref, instructions: "Answer.")

    %{
      run_id: "limit-run",
      cell_id: String.pad_leading(Integer.to_string(sequence), 64, "0"),
      sequence: sequence,
      dimensions: %{
        suite_id: "limits",
        agent_key: "agent",
        agent_spec_id: spec.id,
        scenario_id: "scenario",
        model_key: "model",
        model_ref: model_ref,
        trial: sequence
      },
      sources: %{
        agent_file: "agent.yml",
        scenario_file: "scenario.yml",
        agent_sha256: "agent-sha",
        effective_agent_sha256: "effective-agent-sha",
        scenario_sha256: "scenario-sha"
      },
      scenario: %{turns: [%{id: "one", input: "one", context: %{}, assertions: %{}}]},
      spec: spec,
      runtime_opts: [],
      runtime_limits: limits,
      execution_environment: nil,
      capability_replay: %{mode: :live},
      extensions: Jido.Console.Extensions.Setup.not_requested()
    }
  end

  defp manifest(cells) do
    %{
      schema: "jido.run-manifest",
      schema_version: 1,
      run_id: "limit-run",
      suite_id: "limits",
      suite_file: "suite.yml",
      suite_sha256: "suite-sha",
      versions: %{jido_console: "1", jidoka: "1", elixir: "1", otp: "1"},
      matrix: %{agents: [], models: [], scenarios: [], repeats: 1, cells: length(cells)},
      cells:
        Enum.map(cells, fn cell ->
          %{
            sequence: cell.sequence,
            cell_id: cell.cell_id,
            dimensions: cell.dimensions,
            sources: cell.sources,
            execution_environment: %{status: :not_requested}
          }
        end)
    }
  end

  defp write_suite(root, opts) do
    name = Keyword.get(opts, :name, "suite.yml")
    agent = Path.join(root, "agent.yml")
    scenario = Path.join(root, "scenario.yml")
    suite = Path.join(root, name)
    repeats = Keyword.fetch!(opts, :repeats)
    limits = Keyword.fetch!(opts, :limits)

    File.write!(agent, """
    version: 1
    agent:
      id: limits_agent
      model: openai:gpt-4o-mini
      instructions: Answer.
    """)

    File.write!(scenario, """
    version: 1
    scenario:
      id: limits
      request:
        input: Hello
    """)

    File.write!(suite, """
    version: 1
    suite:
      id: limits
      agents:
        - agent.yml
      scenarios:
        - scenario.yml
      matrix:
        repeats: #{repeats}
      run:
        limits:
          #{limits}
    """)

    suite
  end
end
