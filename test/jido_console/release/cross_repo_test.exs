defmodule Jido.Console.Release.CrossRepoTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.CrossRepo

  setup do
    root = Path.join(System.tmp_dir!(), "jido-cross-repo-test-#{System.unique_integer([:positive])}")
    project = Path.join(root, "jido_console")
    sibling = Path.join(root, "jidoka")
    pinned = Path.join(project, "deps/jidoka")

    Enum.each([project, sibling, pinned], &File.mkdir_p!/1)
    File.mkdir_p!(Path.join(sibling, ".git"))
    File.mkdir_p!(Path.join(pinned, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, project: project, sibling: sibling, pinned: pinned}
  end

  test "tests the clean sibling and the exact locked commit once each", context do
    sibling_commit = String.duplicate("a", 40)
    pinned_commit = String.duplicate("b", 40)
    sibling = context.sibling
    pinned = context.pinned
    {:ok, calls} = Agent.start_link(fn -> [] end)

    runner = fn command, args, opts ->
      Agent.update(calls, &[{command, args, opts} | &1])

      case {command, args, opts[:cd]} do
        {"git", ["rev-parse", "HEAD"], ^sibling} -> {sibling_commit <> "\n", 0}
        {"git", ["rev-parse", "HEAD"], ^pinned} -> {pinned_commit <> "\n", 0}
        {"git", ["status", "--porcelain", "--untracked-files=normal"], _path} -> {"", 0}
        {"mix", _args, _path} -> {"passed\n", 0}
      end
    end

    assert %{
             "pin_names_tested_commit" => true,
             "pinned_commit" => ^pinned_commit,
             "sibling_commit" => ^sibling_commit,
             "test_command" => "mix test --seed 0"
           } =
             CrossRepo.run!(context.project,
               sibling: context.sibling,
               pinned_ref: pinned_commit,
               runner: runner
             )

    calls = Agent.get(calls, &Enum.reverse/1)
    tests = Enum.filter(calls, fn {command, args, _opts} -> command == "mix" and args == ["test", "--seed", "0"] end)
    assert length(tests) == 2

    [sibling_test, pinned_test] = tests
    assert {"JIDO_CONSOLE_JIDOKA_PATH", context.sibling} in elem(sibling_test, 2)[:env]
    assert {"JIDO_CONSOLE_JIDOKA_PATH", nil} in elem(pinned_test, 2)[:env]
    assert {"MIX_BUILD_ROOT", nil} in elem(sibling_test, 2)[:env]
    assert {"MIX_DEPS_PATH", nil} in elem(pinned_test, 2)[:env]
  end

  test "rejects a pinned checkout that does not match the lock", context do
    pinned_ref = String.duplicate("b", 40)

    runner = fn
      "git", ["status", "--porcelain", "--untracked-files=normal"], _opts ->
        {"", 0}

      "git", ["rev-parse", "HEAD"], opts ->
        commit = if opts[:cd] == context.sibling, do: String.duplicate("a", 40), else: String.duplicate("c", 40)
        {commit <> "\n", 0}

      "mix", _args, _opts ->
        {"passed\n", 0}
    end

    assert_raise RuntimeError, ~r/does not name tested dependency commit/, fn ->
      CrossRepo.run!(context.project,
        sibling: context.sibling,
        pinned_ref: pinned_ref,
        runner: runner
      )
    end
  end

  test "reads one immutable GitHub Jidoka pin from the lock" do
    assert CrossRepo.pinned_ref!() == "29246d0a762fe1b17f4250e4f5c98c9f3f6d8419"
  end
end
