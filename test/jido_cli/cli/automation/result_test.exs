defmodule Jido.Cli.Automation.ResultTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Automation.{Contract, Result}

  test "builds the result envelope and normalizes errors" do
    result =
      Result.new(cell(),
        execution: execution(:error),
        evaluation: Result.evaluation([], :error),
        error: Result.error(:failed)
      )

    assert result.schema == "jido.case-result"
    assert result.schema_version == 1
    assert result.turns == []
    assert result.usage == %{}
    assert result.evaluation.status == :not_run
    assert is_binary(result.error.message)
  end

  test "validates JSON round trips and ignores future optional reader fields" do
    result = valid_result()
    decoded = result |> Jason.encode!() |> Jason.decode!() |> Map.put("future_field", true)

    assert {:ok, read} = Contract.read_case_result(decoded)
    assert read.schema == "jido.case-result"
    refute Map.has_key?(read, :future_field)

    assert {:error, {:invalid_automation_contract, :case_result, _errors}} =
             Contract.validate_case_result(decoded)
  end

  test "accepts only namespaced extension identifiers" do
    valid = Map.put(valid_result(), :extensions, %{"acme.metrics" => %{"score" => 1}})
    assert {:ok, _result} = Contract.validate_case_result(valid)

    invalid = Map.put(valid_result(), :extensions, %{"metrics" => %{}})

    assert {:error, {:invalid_automation_contract, :case_result, _errors}} =
             Contract.validate_case_result(invalid)
  end

  test "rejects nonportable error values and map keys" do
    port = Port.open({:spawn, "true"}, [])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    values = [fn -> :ok end, self(), port, make_ref(), %{1 => "bad key"}]

    for value <- values do
      invalid = put_in(valid_result(), [:error, :details], value)

      assert {:error, {:invalid_automation_contract, :case_result, _reason}} =
               Contract.validate_case_result(invalid)
    end
  end

  test "rejects required fields, invalid statuses, and negative bounds" do
    for invalid <- [
          Map.delete(valid_result(), :run_id),
          put_in(valid_result(), [:execution, :status], :unknown),
          put_in(valid_result(), [:execution, :duration_ms], -1),
          %{valid_result() | sequence: 0}
        ] do
      assert {:error, {:invalid_automation_contract, :case_result, _errors}} =
               Contract.validate_case_result(invalid)
    end
  end

  test "aggregates only numeric usage fields" do
    turns = [
      %{usage: %{input_tokens: 2, total_tokens: 3, provider: "a"}},
      %{usage: %{input_tokens: 4, total_tokens: 7}},
      %{}
    ]

    assert Result.usage(turns) == %{input_tokens: 6, total_tokens: 10}
  end

  test "computes passed, failed, and unscored evaluations" do
    assert Result.evaluation([turn([])], :ok).status == :unscored

    passed = [%{name: :contains, status: :passed}]
    assert Result.evaluation([turn(passed)], :ok).status == :passed

    failed = passed ++ [%{name: :equals, status: :failed}]
    evaluation = Result.evaluation([turn(failed)], :ok)
    assert evaluation.status == :failed
    assert evaluation.assertion_count == 2
    assert evaluation.failed_assertion_count == 1
  end

  defp turn(assertions), do: %{evaluation: %{assertions: assertions}}

  defp valid_result do
    Result.new(cell(),
      execution: execution(:error),
      evaluation: Result.evaluation([], :error),
      error: Result.error(:failed)
    )
  end

  defp execution(status) do
    %{
      status: status,
      started_at: "2026-08-12T12:00:00Z",
      duration_ms: 0,
      turn_count: 0
    }
  end

  defp cell do
    %{
      run_id: "run",
      cell_id: "cell",
      sequence: 2,
      dimensions: %{
        suite_id: "suite",
        agent_key: "agent",
        agent_spec_id: "agent",
        scenario_id: "scenario",
        model_key: "declared",
        model_ref: "openai:test",
        trial: 1
      },
      sources: %{
        agent_file: "agent.yml",
        scenario_file: "scenario.yml",
        agent_sha256: "agent-sha",
        effective_agent_sha256: "effective-sha",
        scenario_sha256: "scenario-sha"
      }
    }
  end
end
