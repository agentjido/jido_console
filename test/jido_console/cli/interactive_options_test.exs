defmodule Jido.Console.InteractiveOptionsTest do
  use ExUnit.Case, async: true

  alias Jido.Console.InteractiveOptions

  test "validates interactive parser output" do
    assert {:ok, %{help: true, model: "openai:model"}} =
             InteractiveOptions.parse(help: true, model: "openai:model")

    assert {:error, {:invalid_interactive_options, _errors}} =
             InteractiveOptions.parse(help: "true", unknown: true)
  end
end
