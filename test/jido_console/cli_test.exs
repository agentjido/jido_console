defmodule Jido.ConsoleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defmodule FakeTui do
    def run(opts) do
      send(Keyword.fetch!(opts, :test_pid), :tui_started)
      send(Keyword.fetch!(opts, :test_pid), {:tui_options, opts})
      :ok
    end
  end

  defmodule ErrorTui do
    def run(opts), do: {:error, Keyword.fetch!(opts, :reason)}
  end

  test "rejects unknown options" do
    assert capture_io(:stderr, fn ->
             assert {:error, 1} = Jido.Console.run(["--wat"])
           end) == "jido: unknown option: --wat\n"
  end

  test "rejects positional arguments" do
    assert capture_io(:stderr, fn ->
             assert {:error, 64} = Jido.Console.run(["agent.yaml"])
           end) =~ "Usage:\n  jido"
  end

  test "does not expose removed automation commands" do
    help = capture_io(fn -> assert :ok = Jido.Console.run(["--help"]) end)
    refute help =~ "jido run"
    refute help =~ "jido eval"

    for command <- ["run", "eval"] do
      assert capture_io(:stderr, fn ->
               assert {:error, 64} = Jido.Console.run([command])
             end) =~ "Usage:\n  jido"
    end
  end

  test "starts the TUI with no arguments" do
    assert :ok = Jido.Console.run([], tui: FakeTui, test_pid: self())
    assert_received :tui_started
  end

  test "parses trusted interactive coding selections" do
    assert :ok =
             Jido.Console.run(
               [
                 "--coding-pack",
                 "acme.coding_pack",
                 "--coding-profile",
                 "restricted",
                 "--project-root",
                 "/trusted/project"
               ],
               tui: FakeTui,
               test_pid: self()
             )

    assert_received {:tui_options, options}
    assert options[:coding_pack] == "acme.coding_pack"
    assert options[:coding_profile] == "restricted"
    assert options[:project_root] == "/trusted/project"

    assert :ok =
             Jido.Console.run(["--coding-pack", "disabled"], tui: FakeTui, test_pid: self())

    assert_received {:tui_options, disabled}
    assert disabled[:coding_pack] == :disabled
  end

  test "uses configuration exit status for an invalid coding selection" do
    output =
      capture_io(:stderr, fn ->
        assert {:error, 64} =
                 Jido.Console.run([], tui: ErrorTui, reason: {:invalid_coding_pack, 42})
      end)

    assert output =~ "invalid_coding_pack"
  end

  test "uses configuration exit status for a nested storage startup failure" do
    database = "/private/jido/state/console.sqlite3"
    backup = database <> ".schema-1-backup"

    reason =
      {:jido_console,
       {{:shutdown,
         {:failed_to_start_child, Jido.Console.Storage.Supervisor,
          {:shutdown,
           {:failed_to_start_child, Jido.Console.Storage.SQLite, {:storage_schema_backup_exists, database, backup}}}}},
        {Jido.Console.Application, :start, [:normal, []]}}}

    output =
      capture_io(:stderr, fn ->
        assert {:error, 64} = Jido.Console.run([], tui: ErrorTui, reason: reason)
      end)

    assert output =~ "Old Jido database backup already exists"
  end

  test "defines the built-in agent" do
    assert Jido.Console.version() == to_string(Application.spec(:jido_console, :vsn))
    assert Jido.Console.DefaultAgent.spec().id == "jido"
  end

  test "main handles help and version without starting the application" do
    traced_calls = [
      {Jido.Console.Env, :load_provider_credentials, 0},
      {Jido.Console.Bootstrap, :start_applications, 0},
      {Application, :ensure_all_started, 1}
    ]

    Enum.each(traced_calls, fn {module, _function, _arity} = call ->
      assert {:module, ^module} = Code.ensure_loaded(module)
      assert :erlang.trace_pattern(call, true, [:local]) > 0
    end)

    assert 1 = :erlang.trace(self(), true, [:call])

    try do
      for args <- [["--help"], ["-h"]] do
        assert capture_io(fn -> assert :ok = Jido.Console.main(args) end) =~ "Usage:"
      end

      for args <- [["--version"], ["-v"]] do
        assert capture_io(fn -> assert :ok = Jido.Console.main(args) end) ==
                 "jido #{Jido.Console.version()}\n"
      end
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(traced_calls, &:erlang.trace_pattern(&1, false, [:local]))
    end

    refute_received {:trace, _pid, :call, {Jido.Console.Env, :load_provider_credentials, []}}

    refute_received {:trace, _pid, :call, {Application, :ensure_all_started, [:jido_console]}}
  end

  test "main handles nested command help without starting command services" do
    for args <- [
          ["status", "--help"],
          ["stop", "-h"],
          ["auth", "status", "--help"],
          ["models", "list", "-h"]
        ] do
      assert capture_io(fn -> assert :ok = Jido.Console.CLI.main(args) end) =~ "Usage:"
    end
  end

  test "main runs local status without starting the full application" do
    startup = fn -> flunk("local status started the full application") end

    assert capture_io(fn ->
             assert :ok = Jido.Console.CLI.main(["status"], application_startup: startup)
           end) =~ "jido:"
  end

  test "formats TUI errors at the CLI boundary" do
    reasons = [
      {RuntimeError.exception("exception failure"), "exception failure"},
      {"text failure", "text failure"},
      {{:bad, :reason}, "bad"}
    ]

    for {reason, expected} <- reasons do
      output =
        capture_io(:stderr, fn ->
          assert {:error, 1} = Jido.Console.run([], tui: ErrorTui, reason: reason)
        end)

      assert output =~ expected
    end
  end

  test "prints help for every command family" do
    help_commands = [
      ["status", "--help"],
      ["stop", "-h"],
      ["auth", "--help"],
      ["auth", "-h"],
      ["auth", "status", "--help"],
      ["auth", "doctor", "-h"],
      ["doctor", "--help"],
      ["models", "--help"],
      ["models", "-h"],
      ["models", "list", "--help"],
      ["models", "show", "--help"]
    ]

    Enum.each(help_commands, fn args ->
      assert capture_io(fn -> assert :ok = Jido.Console.run(args) end) =~ "Usage:"
    end)
  end

  test "uses one usage result for malformed command arguments" do
    invalid_commands = [
      ["status", "extra"],
      ["stop", "--unknown"],
      ["auth", "unknown"],
      ["auth", "status", "extra"],
      ["doctor", "--unknown"],
      ["models", "unknown"],
      ["models", "list", "extra"],
      ["models", "show"],
      ["models", "show", "one", "two", "three"],
      ["models", "test", "openai:gpt-4.1-mini"]
    ]

    Enum.each(invalid_commands, fn args ->
      output =
        capture_io(:stderr, fn ->
          assert {:error, 64} = Jido.Console.run(args)
        end)

      assert output != ""
    end)
  end

  test "classifies every interactive configuration failure" do
    reasons = [
      {:invalid_execution_profile, "bad"},
      {:unknown_runtime_profile, "bad"},
      {:unknown_runtime_profile, "bad", :missing},
      :local_coding_root_required,
      :coding_module_name_forbidden,
      :invalid_coding_profile_resolver,
      {:invalid_interactive_options, %{model: ["invalid"]}}
    ]

    Enum.each(reasons, fn reason ->
      assert capture_io(:stderr, fn ->
               assert {:error, 64} = Jido.Console.run([], tui: ErrorTui, reason: reason)
             end) =~ "jido:"
    end)
  end

  test "lists and shows catalog models without credentials" do
    list = capture_io(fn -> assert :ok = Jido.Console.run(["models", "list"]) end)
    assert list =~ "openai\tgpt-4.1-mini\tsupported"
    refute list =~ "sk-"

    shown =
      capture_io(fn ->
        assert :ok = Jido.Console.run(["models", "show", "openai", "gpt-4.1-mini"])
      end)

    assert shown =~ "tier: supported"
    refute shown =~ "sk-"

    single =
      capture_io(fn ->
        assert :ok = Jido.Console.run(["models", "show", "openai:gpt-4.1-mini"])
      end)

    assert single =~ "tier: supported"
  end

  test "reports and stops processes through CLI commands" do
    root = Path.join(System.tmp_dir!(), "jido-cli-process-#{System.unique_integer([:positive])}")
    name = String.to_atom("jido-cli-process-#{System.unique_integer([:positive])}")
    opts = [jido_home: root, name: name]
    {:ok, manager} = Jido.Console.Process.Supervisor.start_link(opts)

    on_exit(fn ->
      if Process.alive?(manager) do
        try do
          GenServer.stop(manager)
        catch
          :exit, _reason -> :ok
        end
      end

      File.rm_rf(root)
    end)

    assert capture_io(fn -> assert :ok = Jido.Console.run(["status"], opts) end) ==
             "jido: no owned background processes\n"

    owner = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, _} = Jido.Console.Process.register(:interactive, owner, opts)

    assert capture_io(fn -> assert :ok = Jido.Console.run(["status"], opts) end) =~ "interactive"

    assert capture_io(fn -> assert :ok = Jido.Console.run(["stop", "--name", "interactive"], opts) end) =~
             "interactive"

    assert capture_io(fn -> assert :ok = Jido.Console.run(["stop"], opts) end) ==
             "jido: no owned background processes\n"
  end

  test "returns a configuration error for an unknown model" do
    unknown =
      capture_io(:stderr, fn ->
        assert {:error, 64} = Jido.Console.run(["models", "show", "openai", "missing"])
      end)

    assert unknown =~ "unknown_model"
  end
end
