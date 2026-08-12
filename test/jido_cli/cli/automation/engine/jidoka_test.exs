defmodule Jido.Cli.Automation.Engine.JidokaTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Automation.Engine.Jidoka, as: Engine
  alias Jidoka.Agent.Spec
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Runtime.LocalOperations

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
      sources: sources(),
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

  test "starts a fresh session for each matrix cell" do
    llm = fn intent, _journal, _context ->
      messages = intent.payload |> get_key(:prompt) |> get_key(:messages, [])

      refute Enum.any?(messages, fn message ->
               get_key(message, :role) == :assistant and
                 get_key(message, :content) == "private answer"
             end)

      {:ok, %{type: :final, content: "private answer"}}
    end

    spec =
      Spec.new!(
        id: "isolated_cell_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Keep cell state isolated."
      )

    first =
      cell(spec, %{id: "one", input: "First", context: %{}, assertions: %{}})
      |> Map.put(:runtime_opts, llm: llm)

    second =
      cell(spec, %{id: "one", input: "Second", context: %{}, assertions: %{}})
      |> Map.put(:cell_id, String.duplicate("d", 64))
      |> Map.put(:runtime_opts, llm: llm)

    assert Engine.run(first, []).execution.status == :ok
    assert Engine.run(second, []).execution.status == :ok
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
      sources: sources(),
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

  test "uses only each sequence step operation results for assertions" do
    llm = fn intent, journal, _context ->
      messages = intent.payload |> get_key(:prompt) |> get_key(:messages, [])

      cond do
        Enum.any?(messages, &(get_key(&1, :content, "") =~ "Call lookup")) and
            count_results(journal, :llm) == 0 ->
          {:ok, %{type: :operation, name: "lookup", arguments: %{}}}

        Enum.any?(messages, &(get_key(&1, :content, "") =~ "Call lookup")) ->
          {:ok, %{type: :final, content: "lookup done"}}

        true ->
          {:ok, %{type: :final, content: "second answer"}}
      end
    end

    operations =
      LocalOperations.operations(%{
        "lookup" => fn _arguments, _context -> %{value: "found"} end
      })

    spec =
      Spec.new!(
        id: "operation_scope_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Use tools when asked.",
        operations: [
          Operation.new!(name: "lookup", description: "Looks up data.", idempotency: :idempotent)
        ]
      )

    result =
      Engine.run(
        cell(spec, [
          %{
            id: "first",
            input: "Call lookup.",
            context: %{},
            assertions: %{operation_called: "lookup"}
          },
          %{
            id: "second",
            input: "Answer without a tool.",
            context: %{},
            assertions: %{operation_called: "lookup"}
          }
        ])
        |> Map.put(:runtime_opts, llm: llm, operations: operations),
        []
      )

    assert result.execution.status == :ok
    assert result.evaluation.status == :failed
    assert Enum.at(result.turns, 0).observations.operation_calls == ["lookup"]
    assert Enum.at(result.turns, 0).evaluation.status == :passed
    assert Enum.at(result.turns, 1).observations.operation_calls == []
    assert Enum.at(result.turns, 1).evaluation.status == :failed
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

  test "keeps the completed prefix and stops after a sequence error" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    llm = fn _intent, _journal, _context ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:ok, %{type: :final, content: "first complete"}}
        1 -> {:error, :provider_offline}
        _call -> flunk("a later scenario turn ran after the sequence error")
      end
    end

    spec =
      Spec.new!(
        id: "prefix_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Answer."
      )

    result =
      Engine.run(
        cell(spec, [
          %{id: "one", input: "First", context: %{}, assertions: %{}},
          %{id: "two", input: "Fail", context: %{}, assertions: %{}},
          %{id: "three", input: "Never", context: %{}, assertions: %{}}
        ])
        |> Map.put(:runtime_opts, llm: llm),
        []
      )

    assert result.execution.status == :error
    assert Enum.map(result.turns, & &1.status) == [:ok, :error]
    assert Enum.map(result.turns, & &1.turn_id) == ["one", "two"]
    assert Agent.get(calls, & &1) == 2
  end

  test "maps a later sequence hibernation and stops the remaining turns" do
    llm = fn intent, journal, _context ->
      messages = intent.payload |> get_key(:prompt) |> get_key(:messages, [])

      cond do
        Enum.any?(messages, &(get_key(&1, :content, "") =~ "First")) ->
          {:ok, %{type: :final, content: "first complete"}}

        count_results(journal, :llm) == 0 ->
          {:ok, %{type: :operation, name: "unsafe_change", arguments: %{}}}

        true ->
          {:ok, %{type: :final, content: "never"}}
      end
    end

    operations =
      LocalOperations.operations(%{
        "unsafe_change" => fn _arguments, _context -> flunk("reviewed operation ran") end
      })

    spec =
      Spec.new!(
        id: "hibernate_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Use the requested tool.",
        operations: [
          Operation.new!(
            name: "unsafe_change",
            description: "Changes data.",
            idempotency: :unsafe_once,
            approval: true
          )
        ]
      )

    result =
      Engine.run(
        cell(spec, [
          %{id: "one", input: "First", context: %{}, assertions: %{}},
          %{id: "two", input: "Change data", context: %{}, assertions: %{}},
          %{id: "three", input: "Never", context: %{}, assertions: %{}}
        ])
        |> Map.put(:runtime_opts, llm: llm, operations: operations),
        []
      )

    assert result.execution.status == :hibernated
    assert Enum.map(result.turns, & &1.status) == [:ok, :hibernated]
    assert Enum.map(result.turns, & &1.turn_id) == ["one", "two"]
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
      sources: sources(),
      spec: spec,
      runtime_opts: [],
      scenario: %{turns: List.wrap(turn)}
    }
  end

  defp count_results(%Effect.Journal{results: results}, kind) do
    results |> Map.values() |> Enum.count(&(&1.kind == kind))
  end

  defp get_key(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp sources do
    %{
      agent_file: "agent.yml",
      scenario_file: "scenario.yml",
      agent_sha256: "agent-sha",
      effective_agent_sha256: "effective-agent-sha",
      scenario_sha256: "scenario-sha"
    }
  end
end
