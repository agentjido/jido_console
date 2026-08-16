defmodule Jido.Console.Automation.CommandTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Automation.Command
  alias Jido.Console.Automation.Command.{Eval, Run}

  test "parses one file input run" do
    assert {:ok, command} =
             Command.parse([
               "run",
               "--agent",
               "agent.yml",
               "--input",
               "prompt.md",
               "--model",
               "openai:gpt-4o-mini"
             ])

    assert %Run{} = command
    assert command.agent == "agent.yml"
    assert command.source == {:input, "prompt.md"}
    assert command.model == "openai:gpt-4o-mini"
  end

  test "requires exactly one input source" do
    assert {:error, :choose_one_input_or_scenario} =
             Command.parse(["run", "--agent", "agent.yml"])

    assert {:error, :choose_one_input_or_scenario} =
             Command.parse([
               "run",
               "--agent",
               "agent.yml",
               "--input",
               "prompt.md",
               "--scenario",
               "scenario.yml"
             ])
  end

  test "parses an eval suite and validates jobs" do
    assert {:ok,
            %Eval{
              suite: "suite.yml",
              jobs: 3,
              runtime_profile: "restricted"
            }} =
             Command.parse([
               "eval",
               "suite.yml",
               "--jobs",
               "3",
               "--runtime-profile",
               "restricted"
             ])

    assert {:error, {:invalid_jobs, 0}} =
             Command.parse(["eval", "suite.yml", "--jobs", "0"])
  end

  test "constructs exact variants and rejects fields from the other command" do
    assert {:ok, %Run{source: {:scenario, "scenario.yml"}}} =
             Command.new(%{name: :run, agent: "agent.yml", scenario: "scenario.yml"})

    assert {:ok, %Eval{suite: "suite.yml"}} =
             Command.new(%{name: :eval, suite: "suite.yml"})

    assert {:error, :choose_one_input_or_scenario} =
             Command.new(%{name: :run, agent: "agent.yml"})

    assert {:error, :choose_one_input_or_scenario} =
             Command.new(%{
               name: :run,
               agent: "agent.yml",
               input: "prompt.md",
               scenario: "scenario.yml"
             })

    assert {:error, :missing_suite} = Command.new(%{name: :eval})

    assert {:error, errors} =
             Command.new(%{
               name: :run,
               agent: "agent.yml",
               input: "prompt.md",
               suite: "suite.yml"
             })

    assert Enum.any?(errors, &match?(%Zoi.Error{code: :unrecognized_key}, &1))

    assert {:error, errors} =
             Command.new(%{name: :eval, suite: "suite.yml", agent: "agent.yml"})

    assert Enum.any?(errors, &match?(%Zoi.Error{code: :unrecognized_key}, &1))
  end

  test "projects exact variants into stable digest data" do
    assert {:ok, command} =
             Command.parse(["run", "--agent", "agent.yml", "--input", "prompt.md"])

    assert Command.digest_projection(command) == %{
             name: :run,
             agent: "agent.yml",
             source: %{kind: :input, path: "prompt.md"},
             model: nil,
             output: nil,
             runtime_profile: nil
           }
  end

  test "exposes schemas, raising construction, and eval digest data" do
    assert %Zoi.Types.Union{} = Command.schema()
    assert %Zoi.Types.Struct{} = Run.schema()
    assert %Zoi.Types.Struct{} = Eval.schema()

    assert %Run{source: {:input, "prompt.md"}} =
             Command.new!(%{
               "name" => :run,
               "agent" => "agent.yml",
               "input" => "prompt.md"
             })

    assert_raise ArgumentError, ~r/invalid Jido.Console command/, fn ->
      Command.new!(%{name: :run, agent: "agent.yml"})
    end

    command =
      Command.new!(%{
        name: :eval,
        suite: "suite.yml",
        jobs: 2,
        output: "results",
        runtime_profile: "restricted"
      })

    assert Command.digest_projection(command) == %{
             name: :eval,
             suite: "suite.yml",
             jobs: 2,
             output: "results",
             runtime_profile: "restricted"
           }
  end

  test "rejects unknown variants and blank runtime profiles" do
    assert {:error, errors} = Command.new(%{name: :unknown})
    assert Enum.all?(errors, &match?(%Zoi.Error{}, &1))

    assert {:error, {:invalid_execution_profile, ""}} =
             Command.new(%{
               name: :run,
               agent: "agent.yml",
               input: "prompt.md",
               runtime_profile: ""
             })

    assert {:error, {:invalid_execution_profile, ""}} =
             Command.new(%{name: :eval, suite: "suite.yml", runtime_profile: ""})

    assert {:error, :choose_one_input_or_scenario} =
             Command.new(%{name: :run, agent: "agent.yml", input: ""})
  end

  test "rejects missing values, extra values, and unknown options" do
    assert {:error, :missing_agent} =
             Command.parse(["run", "--input", "prompt.md"])

    assert {:error, {:unexpected_arguments, ["extra"]}} =
             Command.parse([
               "run",
               "--agent",
               "agent.yml",
               "--input",
               "prompt.md",
               "extra"
             ])

    assert {:error, {:invalid_options, [{"--wat", nil}]}} =
             Command.parse([
               "run",
               "--agent",
               "agent.yml",
               "--input",
               "prompt.md",
               "--wat"
             ])

    assert {:error, :missing_suite} = Command.parse(["eval"])

    assert {:error, {:unexpected_arguments, ["one.yml", "two.yml"]}} =
             Command.parse(["eval", "one.yml", "two.yml"])

    assert {:error, {:invalid_options, [{"--wat", nil}]}} =
             Command.parse(["eval", "suite.yml", "--wat"])

    assert {:error, {:unknown_automation_command, ["compare"]}} =
             Command.parse(["compare"])
  end
end
