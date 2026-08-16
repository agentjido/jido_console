defmodule Jido.Console.Providers.ContractResultTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Providers.ContractResult

  test "normalizes exact string-key results and rejects malformed result sets" do
    assert ContractResult.contract_version() == "jido.provider-contract.v1"
    assert :streaming in ContractResult.dimensions()
    assert :blocked in ContractResult.statuses()

    attrs = %{
      "identity" => "openai:model",
      "dimension" => "streaming",
      "contract_version" => ContractResult.contract_version(),
      "source_mode" => "recorded",
      "status" => "pass",
      "reason" => "recorded evidence",
      "evidence_id" => "evidence",
      "test_id" => "test"
    }

    assert {:ok, result} = ContractResult.new(attrs)
    assert result.dimension == :streaming
    assert result.source_mode == :recorded
    assert {:ok, ^result} = ContractResult.new(result)
    assert {:ok, [^result]} = ContractResult.validate_many([attrs])

    assert {:error, :invalid_provider_contract_result} = ContractResult.new(:invalid)
    assert {:error, :invalid_provider_contract_results} = ContractResult.validate_many(:invalid)

    invalid_fields = [
      Map.delete(attrs, "test_id"),
      Map.put(attrs, "extra", true),
      Map.put(attrs, 42, true)
    ]

    for invalid <- invalid_fields do
      assert {:error, :invalid_provider_contract_result_fields} = ContractResult.new(invalid)
    end

    invalid_values = [
      {"identity", ""},
      {"dimension", "unknown"},
      {"source_mode", "unknown"},
      {"status", "unknown"},
      {"reason", nil}
    ]

    for {field, value} <- invalid_values do
      assert {:error, {:invalid_provider_contract_field, _field}} =
               attrs |> Map.put(field, value) |> ContractResult.new()
    end

    assert {:error, {:unsupported_provider_contract_version, "other"}} =
             attrs |> Map.put("contract_version", "other") |> ContractResult.new()

    assert {:error, {:duplicate_provider_contract_result, {"openai:model", :streaming}}} =
             ContractResult.validate_many([attrs, attrs])

    assert {:error, {:invalid_provider_contract_field, :status}} =
             ContractResult.validate_many([attrs, Map.put(attrs, "status", "bad")])
  end
end
