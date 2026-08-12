defmodule Jido.Cli.Automation.ResultTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Automation.Result

  test "builds the result envelope and normalizes errors" do
    cell = %{
      run_id: "run",
      cell_id: "cell",
      sequence: 2,
      dimensions: %{agent_key: "agent"},
      sources: %{agent_file: "agent.yml"}
    }

    result =
      Result.new(cell,
        execution: %{status: :error},
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
end
