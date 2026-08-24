defmodule Jido.Console.Agents.DefaultTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Agents.Default

  test "keeps the compiled Jido identity and explicit model default" do
    assert %Jidoka.Agent.Spec{id: "jido"} = spec = Default.spec()
    assert Jidoka.Config.model_ref(spec.model) == "openai:gpt-4.1-mini"
    assert apply(Jido.Console.DefaultAgent, :spec, []) == spec
  end
end
