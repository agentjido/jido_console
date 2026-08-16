defmodule Jido.Console.Providers.QualificationTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Models
  alias Jido.Console.Providers.{Qualification, RecordedResults}

  setup do
    {:ok, entry} = Models.show("openai", "gpt-4.1-mini")
    %{entry: entry, results: Enum.filter(RecordedResults.all(), &(&1.identity == entry.identity))}
  end

  test "missing, duplicate, and corrupt evidence fail qualification", %{entry: entry, results: results} do
    incomplete = Enum.reject(results, &(&1.dimension == :streaming))
    identity = entry.identity

    assert {:error, {:missing_provider_contract_results, ^identity, [:streaming]}} =
             Qualification.run("openai", host_env: %{}, recorded_results: incomplete)

    [first | _rest] = results
    dimension = first.dimension

    assert {:error, {:duplicate_provider_contract_result, {^identity, ^dimension}}} =
             Qualification.run("openai", host_env: %{}, recorded_results: [first | results])

    corrupt = Map.delete(first, :test_id)

    assert {:error, :invalid_provider_contract_result_fields} =
             Qualification.run("openai", host_env: %{}, recorded_results: [corrupt | tl(results)])
  end

  test "a failed extra dimension uses the recorded result and blocks support", %{
    results: results
  } do
    failed =
      Enum.map(results, fn result ->
        if result.dimension == :usage do
          %{result | status: :fail, reason: "the observed usage fields were incomplete"}
        else
          result
        end
      end)

    assert {:ok, qualification} =
             Qualification.run("openai", host_env: %{}, recorded_results: failed)

    refute Qualification.supported?(qualification)
    assert [model] = qualification.models
    refute model["eligible"]
    assert model["tier"] == "available"

    assert %{
             "dimension" => "usage",
             "status" => "fail",
             "reason" => "the observed usage fields were incomplete",
             "evidence_id" => "harness:openai:gpt-4.1-mini",
             "test_id" => "openai-gpt-4.1-mini-usage",
             "claim_matches" => false
           } = Enum.find(model["extra"], &(&1["dimension"] == "usage"))
  end

  test "a passing result with a mismatched evidence ID blocks support", %{results: results} do
    mismatched =
      Enum.map(results, fn result ->
        if result.dimension == :tools do
          %{result | evidence_id: "harness:other-observation"}
        else
          result
        end
      end)

    assert {:ok, qualification} =
             Qualification.run("openai", host_env: %{}, recorded_results: mismatched)

    refute Qualification.supported?(qualification)
    assert [model] = qualification.models

    assert %{
             "dimension" => "tools",
             "status" => "pass",
             "evidence_id" => "harness:other-observation",
             "claim_evidence_id" => "harness:openai:gpt-4.1-mini",
             "claim_matches" => false
           } = Enum.find(model["capabilities"], &(&1["dimension"] == "tools"))
  end
end
