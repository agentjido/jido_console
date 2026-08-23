defmodule Jido.Console.TermUIDependencyTest do
  use ExUnit.Case, async: true

  @term_ui_ref "4314b8302c5fce7f2ac486ff319731bb1ddf147f"

  test "uses either the immutable TermUI pin or the explicit local checkout" do
    {_app, options} =
      Mix.Project.config()
      |> Keyword.fetch!(:deps)
      |> Enum.find(fn {app, _options} -> app == :term_ui end)

    case System.get_env("JIDO_CONSOLE_TERM_UI_PATH") do
      nil ->
        assert options[:github] == "mikehostetler/term_ui"
        assert options[:ref] == @term_ui_ref
        refute Keyword.has_key?(options, :path)
        refute Keyword.has_key?(options, :branch)

        assert {:git, "https://github.com/mikehostetler/term_ui.git", @term_ui_ref, lock_options} =
                 Mix.Dep.Lock.read()[:term_ui]

        assert lock_options[:ref] == @term_ui_ref

      checkout ->
        assert Path.expand(options[:path]) == Path.expand(checkout)
        refute Keyword.has_key?(options, :github)
        refute Keyword.has_key?(options, :ref)
        refute Keyword.has_key?(options, :branch)
    end
  end
end
