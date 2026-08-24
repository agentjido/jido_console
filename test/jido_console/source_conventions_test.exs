defmodule Jido.Console.SourceConventionsTest do
  use ExUnit.Case, async: true

  @source_files Path.wildcard("lib/**/*.ex")
  @profile_boundary_files MapSet.new([
                            "lib/jido_console/agent_source/admission.ex",
                            "lib/jido_console/cli.ex",
                            "lib/jido_console/cli/interactive_options.ex",
                            "lib/jido_console/cli/tui/app.ex",
                            "lib/jido_console/cli/tui/command.ex",
                            "lib/jido_console/cli/tui/effects.ex",
                            "lib/jido_console/cli/tui/selection.ex",
                            "lib/jido_console/coding/local.ex",
                            "lib/jido_console/coding/local/adapter.ex",
                            "lib/jido_console/coding/profile.ex",
                            "lib/jido_console/coding/selection.ex",
                            "lib/jido_console/coding/setup.ex",
                            "lib/jido_console/error.ex",
                            "lib/jido_console/execution_policy.ex",
                            "lib/jido_console/execution_policy/configuration.ex",
                            "lib/jido_console/execution_policy/definition.ex",
                            "lib/jido_console/execution_policy/record.ex",
                            "lib/jido_console/execution_policy/registry.ex",
                            "lib/jido_console/execution_policy/selection.ex",
                            "lib/jido_console/session/client.ex",
                            "lib/jido_console/session/selection.ex",
                            "lib/jido_console/session/thread_resources.ex"
                          ])

  test "all explicit production structs derive their shape from Zoi" do
    violations =
      Enum.flat_map(@source_files, fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, number} ->
          if Regex.match?(~r/^\s*defstruct\b/, line) and
               not String.contains?(line, "defstruct Zoi.Struct.struct_fields(") do
            ["#{path}:#{number}"]
          else
            []
          end
        end)
      end)

    assert violations == [],
           "explicit structs must derive fields and defaults from a Zoi schema:\n" <>
             Enum.join(violations, "\n")
  end

  test "production source does not define a parallel exception taxonomy" do
    violations =
      Enum.filter(@source_files, fn path ->
        Regex.match?(~r/^\s*defexception\b/m, File.read!(path))
      end)

    assert violations == [],
           "project exceptions must use Jido.Console.Error and Splode:\n" <>
             Enum.join(violations, "\n")
  end

  test "profile terms stay in Jidoka adapters and migration facades" do
    violations =
      Enum.filter(@source_files, fn path ->
        source = File.read!(path)

        Regex.match?(~r/coding_profile|profile_id|profile_warning|\bprofile\b/i, source) and
          not MapSet.member?(@profile_boundary_files, path)
      end)

    assert violations == [],
           "Console profile terms must stay in an exact boundary allowlist:\n" <>
             Enum.join(violations, "\n")
  end

  test "guides lead with canonical agent and execution-policy names" do
    readme = File.read!("README.md")
    guide = File.read!("guides/jido-console.md")
    [canonical_guide, deprecated] = String.split(guide, "## Deprecated Names", parts: 2)

    assert readme =~ "--agent"
    assert readme =~ "--execution-policy"
    assert canonical_guide =~ "/agent"
    assert canonical_guide =~ "/execution-policy"
    refute readme =~ "--coding-profile"
    refute canonical_guide =~ "--coding-profile"
    refute canonical_guide =~ ":coding_profile"
    refute canonical_guide =~ "/profile"
    assert deprecated =~ "--coding-profile"
    assert deprecated =~ ":coding_profile"
    assert deprecated =~ "/profile"
    refute readme =~ "jido run --agent"
    refute guide =~ "jido run --agent"
  end
end
