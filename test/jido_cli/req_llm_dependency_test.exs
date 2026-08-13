defmodule Jido.Cli.ReqLLMDependencyTest do
  use ExUnit.Case, async: true

  @supported_req_llm "~> 1.20.0"

  test "uses the supported ReqLLM adapter line" do
    requirement =
      Mix.Project.config()
      |> Keyword.fetch!(:deps)
      |> Enum.find_value(fn
        {:req_llm, requirement} -> requirement
        {:req_llm, requirement, _opts} -> requirement
        _dependency -> nil
      end)

    resolved_version = :req_llm |> Application.spec(:vsn) |> to_string()

    assert requirement == @supported_req_llm
    assert Version.match?(resolved_version, @supported_req_llm)

    assert {:hex, :req_llm, ^resolved_version, _checksum, _managers, _deps, "hexpm", _outer_checksum} =
             Mix.Dep.Lock.read()[:req_llm]
  end

  if System.get_env("JIDO_CLI_JIDOKA_PATH") do
    test "the local Jidoka adapter accepts ReqLLM decoded object parts" do
      object = %{"type" => "operation", "name" => "lookup", "arguments" => %{}}

      response = %ReqLLM.Response{
        id: "response-1",
        model: "gpt-4.1-mini",
        context: ReqLLM.Context.new([]),
        message: ReqLLM.Context.assistant([%{type: :object, object: object}])
      }

      assert {:ok, decision} =
               Jidoka.Adapter.ReqLLM.ResponseAdapter.decision(response, nil, Jason.encode!(object))

      assert decision.type == :operation
      assert decision.name == "lookup"
      assert decision.arguments == %{}
      assert decision.parts == []
    end
  end
end
