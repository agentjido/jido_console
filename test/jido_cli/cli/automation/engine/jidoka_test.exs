defmodule Jido.Cli.Automation.Engine.JidokaTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Automation.Engine.Jidoka, as: Engine
  alias Jidoka.Agent.Spec

  test "runs ordered turns in one session and carries prior agent state" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    llm = fn intent, _journal, _context ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})

      messages = intent.payload |> get_key(:prompt) |> get_key(:messages, [])

      case call do
        0 ->
          {:ok, %{type: :final, content: "Stored Atlas"}}

        1 ->
          assert Enum.any?(messages, fn message ->
                   Map.get(message, :role) == :assistant and
                     Map.get(message, :content) == "Stored Atlas"
                 end)

          {:ok, %{type: :final, content: "Atlas"}}
      end
    end

    spec =
      Spec.new!(
        id: "memory_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Remember facts from earlier turns."
      )

    cell = %{
      run_id: "run-fixed",
      cell_id: String.duplicate("a", 64),
      sequence: 1,
      dimensions: %{
        suite_id: "multi",
        agent_key: "memory",
        agent_spec_id: "memory_agent",
        scenario_id: "remember",
        model_key: "declared",
        model_ref: "openai:gpt-4o-mini",
        trial: 1
      },
      sources: %{},
      spec: spec,
      runtime_opts: [llm: llm],
      scenario: %{
        turns: [
          %{
            id: "store",
            input: "My project is Atlas.",
            context: %{},
            assertions: %{contains: "Atlas"}
          },
          %{
            id: "recall",
            input: "What is my project?",
            context: %{},
            assertions: %{equals: "Atlas"}
          }
        ]
      }
    }

    result = Engine.run(cell, [])

    assert result.execution.status == :ok, inspect(result.error)
    assert result.evaluation.status == :passed
    assert Enum.map(result.turns, & &1.response.content) == ["Stored Atlas", "Atlas"]
    assert Enum.map(result.turns, & &1.evaluation.status) == [:passed, :passed]
    assert Agent.get(calls, & &1) == 2
  end

  test "reports an assertion failure without changing execution status" do
    llm = fn _intent, _journal, _context ->
      {:ok, %{type: :final, content: "actual"}}
    end

    spec =
      Spec.new!(
        id: "assertion_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    cell = %{
      run_id: "run-fixed",
      cell_id: String.duplicate("b", 64),
      sequence: 1,
      dimensions: %{
        suite_id: "assertions",
        agent_key: "agent",
        agent_spec_id: "assertion_agent",
        scenario_id: "failure",
        model_key: "declared",
        model_ref: "openai:gpt-4o-mini",
        trial: 1
      },
      sources: %{},
      spec: spec,
      runtime_opts: [llm: llm],
      scenario: %{
        turns: [
          %{id: "one", input: "Answer", context: %{}, assertions: %{equals: "expected"}}
        ]
      }
    }

    result = Engine.run(cell, [])
    assert result.execution.status == :ok, inspect(result.error)
    assert result.evaluation.status == :failed
    assert result.evaluation.failed_assertion_count == 1
  end

  test "reports a runtime failure and keeps the interrupted turn" do
    llm = fn _intent, _journal, _context -> {:error, :provider_offline} end

    spec =
      Spec.new!(
        id: "error_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    cell =
      spec
      |> cell(%{id: "failure", input: "Answer", context: %{}, assertions: %{}})
      |> Map.put(:runtime_opts, llm: llm)

    result = Engine.run(cell, [])

    assert result.execution.status == :error
    assert result.evaluation.status == :not_run
    assert [%{turn_id: "failure", status: :error, error: error}] = result.turns
    assert is_binary(error.message)
  end

  test "supports unscored turns and injected clocks" do
    llm = fn _intent, _journal, _context -> {:ok, %{type: :final, content: "answer"}} end

    spec =
      Spec.new!(
        id: "clock_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    {:ok, clock} = Agent.start_link(fn -> 10 end)

    monotonic_ms = fn -> Agent.get_and_update(clock, &{&1, &1 + 5}) end
    utc_now = fn -> ~U[2026-08-12 12:00:00Z] end

    cell =
      spec
      |> cell(%{id: "plain", input: "Answer", context: %{}, assertions: %{}})
      |> Map.put(:runtime_opts, llm: llm)

    result = Engine.run(cell, monotonic_ms: monotonic_ms, utc_now: utc_now)

    assert result.execution.status == :ok
    assert result.execution.started_at == "2026-08-12T12:00:00Z"
    assert result.evaluation.status == :unscored
    assert result.execution.duration_ms > 0
  end

  test "reports invalid request data before a session turn" do
    spec =
      Spec.new!(
        id: "invalid_request_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    result =
      Engine.run(
        cell(spec, %{id: "bad", input: "Answer", context: [:not, :a, :map], assertions: %{}}),
        []
      )

    assert result.execution.status == :error
    assert [%{status: :error}] = result.turns
  end

  defp cell(spec, turn) do
    %{
      run_id: "run-fixed",
      cell_id: String.duplicate("c", 64),
      sequence: 1,
      dimensions: %{
        suite_id: "engine",
        agent_key: "agent",
        agent_spec_id: spec.id,
        scenario_id: "engine",
        model_key: "declared",
        model_ref: "openai:gpt-4o-mini",
        trial: 1
      },
      sources: %{},
      spec: spec,
      runtime_opts: [],
      scenario: %{turns: [turn]}
    }
  end

  defp get_key(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
