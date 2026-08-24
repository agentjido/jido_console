defmodule Jido.Console.Tui.CommandTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.Command

  test "parses registered commands into typed actions" do
    assert {:command, :help} = Command.parse("/help")
    assert {:command, :show_agent} = Command.parse("/agent")

    assert {:command, {:select_agent, "agents/review agent.yaml"}} =
             Command.parse(" /agent   agents/review agent.yaml  ")

    assert {:command, :list_models} = Command.parse(" /model ")

    assert {:command, {:select_model, "openai:gpt-4.1-mini"}} =
             Command.parse("\t/model   openai:gpt-4.1-mini  ")

    assert {:command, :list_execution_policies} = Command.parse("/execution-policy")

    assert {:command, {:select_execution_policy, "coding.restricted"}} =
             Command.parse("/execution-policy coding.restricted")

    assert {:command, :list_profiles} = Command.parse("/profile")

    assert {:command, {:select_profile, "coding.restricted"}} =
             Command.parse("/profile coding.restricted")

    assert {:command, :new_session} = Command.parse("/new-session")
    assert {:command, :cancel} = Command.parse("/cancel")
  end

  test "leaves non-leading slash text as a prompt" do
    assert :prompt = Command.parse("explain /model")
    assert :prompt = Command.parse("plain prompt")
  end

  test "keeps malformed command attempts out of the prompt path" do
    for input <- [
          "/MODEL",
          "/",
          "//model",
          "/model\nopenai:gpt-4.1-mini",
          "/model openai:gpt-4.1-mini extra",
          "/execution-policy coding.restricted extra",
          "/help extra"
        ] do
      assert {:error, error} = Command.parse(input), input
      assert Exception.message(error) != ""
    end
  end

  test "generates stable help from the registry" do
    help = Command.help()

    assert help =~ "/agent [source]"
    assert help =~ "/execution-policy [id]"
    assert help =~ "/help"
    assert help =~ "/model [provider:model]"
    assert help =~ "/new-session"
    assert help =~ "/cancel"
    assert help =~ "/profile [profile]"

    assert String.split(help, "\n") == Enum.sort(String.split(help, "\n"))
  end

  test "advertises only the model argument completion source" do
    registry = Command.registry()

    assert Enum.find(registry, &(&1.name == "model")).argument_source == :models

    assert registry
           |> Enum.reject(&(&1.name == "model"))
           |> Enum.all?(&(not Map.has_key?(&1, :argument_source)))
  end

  test "unknown command feedback names available commands" do
    assert {:error, error} = Command.parse("/missing")
    message = Exception.message(error)
    assert message =~ "Unknown command /missing"
    assert message =~ "/agent"
    assert message =~ "/execution-policy"
    assert message =~ "/help"
    assert message =~ "/model"
    assert message =~ "/profile"
    assert message =~ "/new-session"
    assert message =~ "/cancel"
  end
end
