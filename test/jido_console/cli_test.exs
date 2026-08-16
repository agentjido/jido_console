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

  defmodule FakeAutomation do
    def execute(args, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:automation_started, args})
      send(Keyword.fetch!(opts, :test_pid), {:automation_options, opts})
      Keyword.get(opts, :automation_result, {:ok, %{status: :passed}})
    end
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

  test "sends run commands to the automation boundary" do
    args = ["run", "--agent", "agent.yml", "--input", "prompt.md"]

    assert :ok =
             Jido.Console.run(args,
               automation: FakeAutomation,
               test_pid: self()
             )

    assert_received {:automation_started, ^args}
    assert_received {:automation_options, options}
    assert options[:cancellation_source] == Jido.Console.Automation.Interrupt.Signal
  end

  test "sends eval commands to the automation boundary" do
    args = ["eval", "suite.yml"]

    assert :ok =
             Jido.Console.run(args,
               automation: FakeAutomation,
               test_pid: self()
             )

    assert_received {:automation_started, ^args}
  end

  test "maps failed evaluations and automation errors to exit statuses" do
    opts = [automation: FakeAutomation, test_pid: self()]

    failed_output =
      capture_io(:stderr, fn ->
        assert {:error, 1} =
                 Jido.Console.run(
                   ["eval", "suite.yml"],
                   opts ++
                     [
                       automation_result:
                         {:ok,
                          %{
                            status: :failed,
                            counts: %{failed: 2, errors: 1}
                          }}
                     ]
                 )
      end)

    assert failed_output =~ "2 failed, 1 errors"

    cancelled_output =
      capture_io(:stderr, fn ->
        assert {:error, 1} =
                 Jido.Console.run(
                   ["eval", "suite.yml"],
                   opts ++
                     [
                       automation_result:
                         {:ok,
                          %{
                            status: :cancelled,
                            counts: %{failed: 0, errors: 0, cancelled: 1}
                          }}
                     ]
                 )
      end)

    assert cancelled_output =~ "automated run cancelled"

    usage_output =
      capture_io(:stderr, fn ->
        assert {:error, 64} =
                 Jido.Console.run(
                   ["run"],
                   opts ++ [automation_result: {:error, :usage, "missing agent"}]
                 )
      end)

    assert usage_output == "jido: missing agent\n"

    execution_output =
      capture_io(:stderr, fn ->
        assert {:error, 1} =
                 Jido.Console.run(
                   ["eval", "suite.yml"],
                   opts ++ [automation_result: {:error, :execution, "write failed"}]
                 )
      end)

    assert execution_output == "jido: write failed\n"
  end

  test "rejects an invalid automation boundary result" do
    output =
      capture_io(:stderr, fn ->
        assert {:error, 1} =
                 Jido.Console.run(["eval", "suite.yml"],
                   automation: FakeAutomation,
                   test_pid: self(),
                   automation_result: :invalid
                 )
      end)

    assert output =~ "invalid automation result"
  end

  test "defines the built-in agent" do
    assert Jido.Console.DefaultAgent.spec().id == "jido"
  end

  test "main handles help and version without starting the application" do
    traced_calls = [
      {Jido.Console.Env, :load_provider_credentials, 0},
      {Application, :ensure_all_started, 1}
    ]

    Enum.each(traced_calls, fn {module, _function, _arity} = call ->
      assert {:module, ^module} = Code.ensure_loaded(module)
      assert :erlang.trace_pattern(call, true, [:local]) > 0
    end)

    assert 1 = :erlang.trace(self(), true, [:call])

    try do
      for args <- [
            ["--help"],
            ["-h"],
            ["run", "--help"],
            ["run", "-h"],
            ["eval", "--help"],
            ["eval", "-h"]
          ] do
        assert capture_io(fn -> assert :ok = Jido.Console.main(args) end) =~ "Usage:"
      end

      for args <- [["--version"], ["-v"]] do
        assert capture_io(fn -> assert :ok = Jido.Console.main(args) end) ==
                 "jido #{Jido.Console.Release.Identity.version()}\n"
      end
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(traced_calls, &:erlang.trace_pattern(&1, false, [:local]))
    end

    refute_received {:trace, _pid, :call, {Jido.Console.Env, :load_provider_credentials, []}}

    refute_received {:trace, _pid, :call, {Application, :ensure_all_started, [:jido_console]}}
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
      ["models", "show", "--help"],
      ["models", "test", "-h"]
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
      ["models", "test", "openai:gpt-4.1-mini", "--unknown"]
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
  end

  test "tests recorded contracts and denies offline or unsupported features" do
    tested =
      capture_io(fn ->
        assert :ok = Jido.Console.run(["models", "test", "openai:gpt-4.1-mini"])
      end)

    assert tested =~ "contract.streaming: pass"

    offline =
      capture_io(fn ->
        assert {:error, 1} = Jido.Console.run(["models", "test", "openai", "gpt-4.1-mini", "--offline"])
      end)

    assert offline =~ "offline: deny"

    denied =
      capture_io(fn ->
        assert {:error, 1} = Jido.Console.run(["models", "test", "ollama", "llama3.2", "--require", "streaming"])
      end)

    assert denied =~ "preflight: deny"

    unknown =
      capture_io(:stderr, fn ->
        assert {:error, 64} = Jido.Console.run(["models", "show", "openai", "missing"])
      end)

    assert unknown =~ "unknown_model"
  end
end
