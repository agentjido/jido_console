defmodule Jido.Console.JidokaDependencyTest do
  use ExUnit.Case, async: true

  @jidoka_ref "419bb36b428c8ef3e0a06455d4e90ba409573f59"

  test "the default build uses the immutable GitHub Jidoka dependency" do
    if System.get_env("JIDO_CONSOLE_JIDOKA_PATH") do
      assert Mix.env() in [:dev, :test]
    else
      {_app, options} =
        Mix.Project.config()
        |> Keyword.fetch!(:deps)
        |> Enum.find(fn {app, _options} -> app == :jidoka end)

      assert options[:github] == "agentjido/jidoka"
      assert options[:ref] == @jidoka_ref
      refute Keyword.has_key?(options, :path)

      assert {:git, "https://github.com/agentjido/jidoka.git", @jidoka_ref, options} =
               Mix.Dep.Lock.read()[:jidoka]

      assert options[:ref] == @jidoka_ref
    end
  end
end
