defmodule Jido.Console.Tui.CommandTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.Command

  test "parses registered commands into typed actions" do
    assert {:command, :help} = Command.parse("/help")
    assert {:command, :list_models} = Command.parse(" /model ")

    assert {:command, {:select_model, "openai:gpt-4.1-mini"}} =
             Command.parse("\t/model   openai:gpt-4.1-mini  ")

    assert {:command, :list_profiles} = Command.parse("/profile")

    assert {:command, {:select_profile, "coding.restricted"}} =
             Command.parse("/profile coding.restricted")
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
          "/help extra"
        ] do
      assert {:error, error} = Command.parse(input), input
      assert Exception.message(error) != ""
    end
  end

  test "generates stable help from the registry" do
    help = Command.help()

    assert help =~ "/help"
    assert help =~ "/model [provider:model]"
    assert help =~ "/profile [profile]"

    assert String.split(help, "\n") == Enum.sort(String.split(help, "\n"))
  end

  test "unknown command feedback names available commands" do
    assert {:error, error} = Command.parse("/missing")
    message = Exception.message(error)
    assert message =~ "Unknown command /missing"
    assert message =~ "/help"
    assert message =~ "/model"
    assert message =~ "/profile"
  end
end
