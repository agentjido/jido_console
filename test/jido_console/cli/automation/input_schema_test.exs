defmodule Jido.Console.Automation.InputSchemaTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Automation.InputSchema

  test "tags exact suite references and model alternatives" do
    document = %{
      "suite" => %{
        "id" => "matrix",
        "agents" => ["agent.yml", %{"file" => "other.yml", "key" => "other"}],
        "scenarios" => ["scenario.yml"],
        "models" => [
          %{"source" => "agent"},
          %{"key" => "override", "ref" => "openai:gpt-4o-mini", "generation" => %{"seed" => 4}}
        ]
      }
    }

    assert {:ok, %{"suite" => suite}} = InputSchema.validate_suite(document, "suite.yml")

    assert suite["agents"] == [
             {:file, "agent.yml", nil},
             {:file, "other.yml", "other"}
           ]

    assert suite["scenarios"] == [{:file, "scenario.yml"}]

    assert suite["models"] == [
             {:agent, nil},
             {:override, "openai:gpt-4o-mini", "override", %{"seed" => 4}}
           ]
  end

  test "normalizes request and nested request forms into tagged turns" do
    request_document = %{
      "scenario" => %{
        "id" => "single",
        "request" => %{"id" => "ask", "input" => %{"file" => "prompt.md"}},
        "assertions" => %{"contains" => "answer"}
      }
    }

    assert {:ok, %{"scenario" => %{"turns" => [request_turn]}}} =
             InputSchema.validate_scenario(request_document, "request.yml")

    assert request_turn == %{
             "id" => "ask",
             "input" => {:file, "prompt.md"},
             "assertions" => %{"contains" => "answer"}
           }

    turns_document = %{
      "scenario" => %{
        "id" => "turns",
        "turns" => [
          %{"input" => %{"text" => "direct"}},
          %{"request" => %{"input" => "nested", "context" => %{"tenant" => "acme"}}}
        ]
      }
    }

    assert {:ok, %{"scenario" => %{"turns" => [direct, nested]}}} =
             InputSchema.validate_scenario(turns_document, "turns.yml")

    assert direct["input"] == {:text, "direct"}
    assert nested["input"] == {:text, "nested"}
    assert nested["context"] == %{"tenant" => "acme"}
    refute Map.has_key?(nested, "request")
  end

  test "rejects ambiguous and empty source alternatives" do
    invalid_scenarios = [
      %{"id" => "empty"},
      %{"id" => "both", "turns" => [%{"input" => "one"}], "request" => %{"input" => "two"}},
      %{"id" => "turn-both", "turns" => [%{"input" => "one", "request" => %{"input" => "two"}}]},
      %{"id" => "source-both", "turns" => [%{"input" => %{"text" => "one", "file" => "two.md"}}]},
      %{"id" => "source-empty", "turns" => [%{"input" => %{}}]}
    ]

    for scenario <- invalid_scenarios do
      assert {:error, {:document_schema_invalid, {:scenario, "invalid.yml"}, _errors}} =
               InputSchema.validate_scenario(%{"scenario" => scenario}, "invalid.yml")
    end
  end

  test "rejects model entries with both or neither source form" do
    for model <- [%{"source" => "agent", "ref" => "openai:gpt-4o-mini"}, %{"key" => "missing"}] do
      document = %{
        "suite" => %{
          "id" => "invalid",
          "agents" => ["agent.yml"],
          "scenarios" => ["scenario.yml"],
          "models" => [model]
        }
      }

      assert {:error, {:document_schema_invalid, {:suite, "invalid.yml"}, _errors}} =
               InputSchema.validate_suite(document, "invalid.yml")
    end
  end
end
