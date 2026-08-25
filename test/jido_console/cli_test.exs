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

  defmodule FakeJSON do
    def run(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:json_started, opts})
      :ok
    end
  end

  test "rejects unknown options" do
    assert capture_io(:stderr, fn ->
             assert {:error, 1} = Jido.Console.run(["--wat"])
           end) == "jido: unknown option: --wat\n"
  end

  test "shows canonical interactive flags before one deprecated alias section" do
    help = capture_io(fn -> assert :ok = Jido.Console.run(["--help"]) end)

    assert help =~ "--agent SOURCE"
    assert help =~ "--execution-policy ID"
    assert help =~ "Deprecated aliases:"
    assert help =~ "--coding-profile ID"
    assert count(help, "Deprecated aliases:") == 1
    assert index(help, "--execution-policy ID") < index(help, "--coding-profile ID")
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

  test "starts the JSON client after runtime startup and forwards trusted options" do
    test_pid = self()

    startup = fn ->
      send(test_pid, :application_started)
      :ok
    end

    output =
      capture_io(fn ->
        assert :ok =
                 Jido.Console.run(
                   [
                     "json",
                     "--coding-pack",
                     "disabled",
                     "--coding-profile",
                     "restricted",
                     "--project-root",
                     "/trusted/project",
                     "--model",
                     "openai:gpt-4.1-mini"
                   ],
                   json_client: FakeJSON,
                   test_pid: test_pid,
                   application_startup: startup
                 )
      end)

    assert output == ""
    assert_receive :application_started
    assert_receive {:json_started, options}
    assert options[:coding_pack] == :disabled
    assert options[:execution_policy] == "restricted"
    assert options[:execution_policy_direct_choice].origin == :cli
    assert options[:deprecation_warnings] == [Jido.Console.ExecutionPolicy.legacy_warning()]
    refute Keyword.has_key?(options, :coding_profile)
    assert options[:project_root] == "/trusted/project"
    assert options[:model] == "openai:gpt-4.1-mini"
  end

  test "shows JSON help without starting the runtime" do
    startup = fn -> flunk("JSON help started the runtime") end
    help = capture_io(fn -> assert :ok = Jido.Console.CLI.main(["json", "--help"], application_startup: startup) end)
    assert help =~ "jido json [OPTIONS]"
    assert help =~ "experimental `json` client"
  end

  test "main opens the TUI before application startup" do
    test_pid = self()

    output =
      capture_io(:stderr, fn ->
        assert :ok =
                 Jido.Console.CLI.main([],
                   tui: FakeTui,
                   test_pid: test_pid,
                   application_startup: fn ->
                     send(test_pid, :application_started)
                     :ok
                   end
                 )
      end)

    assert output == ""
    assert_receive :tui_started
    refute_receive :application_started

    assert_received {:tui_options, options}
    assert is_function(options[:application_startup], 0)
  end

  test "parses canonical interactive selections" do
    assert :ok =
             Jido.Console.run(
               [
                 "--agent",
                 "agents/review agent.yaml",
                 "--coding-pack",
                 "acme.coding_pack",
                 "--execution-policy",
                 "coding.restricted",
                 "--project-root",
                 "/trusted/project"
               ],
               tui: FakeTui,
               test_pid: self()
             )

    assert_received {:tui_options, options}
    assert options[:agent_source] == "agents/review agent.yaml"
    assert options[:coding_pack] == "acme.coding_pack"
    assert options[:execution_policy] == "coding.restricted"
    assert options[:execution_policy_direct_choice].origin == :cli
    assert options[:project_root] == "/trusted/project"

    assert :ok =
             Jido.Console.run(["--coding-pack", "disabled"], tui: FakeTui, test_pid: self())

    assert_received {:tui_options, disabled}
    assert disabled[:coding_pack] == :disabled
  end

  test "accepts the legacy CLI policy name with one warning" do
    output =
      capture_io(:stderr, fn ->
        assert :ok =
                 Jido.Console.run(
                   ["--coding-profile", "coding.local"],
                   tui: FakeTui,
                   test_pid: self()
                 )
      end)

    assert output == "jido: warning: coding profile is deprecated; use execution policy\n"
    assert_received {:tui_options, options}
    assert options[:execution_policy] == "coding.trusted-workspace"
    refute Keyword.has_key?(options, :coding_profile)
  end

  test "rejects policy conflicts and repeated canonical flags" do
    for args <- [
          [
            "--execution-policy",
            "coding.restricted",
            "--coding-profile",
            "coding.restricted"
          ],
          [
            "--execution-policy",
            "coding.restricted",
            "--execution-policy",
            "coding.restricted"
          ]
        ] do
      output =
        capture_io(:stderr, fn ->
          assert {:error, 64} = Jido.Console.run(args, tui: FakeTui, test_pid: self())
        end)

      assert output =~ "jido:"
      refute_received :tui_started
    end
  end

  test "uses configuration exit status for an invalid coding selection" do
    output =
      capture_io(:stderr, fn ->
        assert {:error, 64} =
                 Jido.Console.run([], tui: ErrorTui, reason: {:invalid_coding_pack, 42})
      end)

    assert output =~ "invalid_coding_pack"
  end

  test "uses configuration status for source and policy errors and runtime status for open errors" do
    for reason <- [:agent_source_missing, {:unknown_execution_policy, "missing"}] do
      assert capture_io(:stderr, fn ->
               assert {:error, 64} = Jido.Console.run([], tui: ErrorTui, reason: reason)
             end) =~ "jido:"
    end

    assert capture_io(:stderr, fn ->
             assert {:error, 1} =
                      Jido.Console.run([], tui: ErrorTui, reason: :restricted_enforcement_unavailable)
           end) =~ "jido:"
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

    assert output =~ "old Jido database backup already exists"
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
    root = Path.join(System.tmp_dir!(), "jido-cli-status-#{System.unique_integer([:positive])}")
    startup = fn -> flunk("local status started the full application") end
    on_exit(fn -> File.rm_rf!(root) end)

    assert capture_io(fn ->
             assert :ok =
                      Jido.Console.CLI.main(["status"],
                        application_startup: startup,
                        jido_home: root
                      )
           end) =~ "jido:"
  end

  test "main stops without starting the application" do
    root = Path.join(System.tmp_dir!(), "jido-cli-stop-#{System.unique_integer([:positive])}")
    startup = fn -> flunk("stop started the full application") end
    on_exit(fn -> File.rm_rf(root) end)

    assert capture_io(fn ->
             assert :ok =
                      Jido.Console.CLI.main(["stop"],
                        jido_home: root,
                        application_startup: startup
                      )
           end) == "jido: no owned background processes\n"
  end

  test "a separate stop process terminates the owner while its Jido home is locked" do
    root = Path.join(System.tmp_dir!(), "jido-cli-cross-process-stop-#{System.unique_integer([:positive])}")
    mix = System.find_executable("mix") || flunk("mix executable is unavailable")
    project = File.cwd!()

    owner_script = """
    Application.put_env(:jido_console, :storage_options, jido_home: #{inspect(root)})
    {:ok, _applications} = Application.ensure_all_started(:jido_console)
    {:ok, _record} = Jido.Console.Process.register(:interactive, self(), jido_home: #{inspect(root)})
    IO.puts("JIDO_OWNER_READY")
    Process.sleep(:infinity)
    """

    owner =
      Port.open(
        {:spawn_executable, mix},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          args: ["run", "--no-start", "--no-compile", "-e", owner_script],
          cd: project,
          env: [{~c"MIX_ENV", ~c"test"}, {~c"JIDO_HOME", String.to_charlist(root)}]
        ]
      )

    on_exit(fn ->
      stop_port(owner)
      File.rm_rf(root)
    end)

    assert await_port_output(owner, "JIDO_OWNER_READY", 5_000) =~ "JIDO_OWNER_READY"
    assert {:ok, [%{name: "interactive", status: :ready}]} = Jido.Console.Process.list(jido_home: root)

    previous = Process.flag(:trap_exit, true)

    try do
      path = Path.join(root, "state/console-lock.sqlite3")

      assert {:error, {:home_locked, ^path}} =
               Jido.Console.Storage.HomeLock.start_link(
                 jido_home: root,
                 name: String.to_atom("cross-process-lock-#{System.unique_integer([:positive])}")
               )
    after
      Process.flag(:trap_exit, previous)
    end

    assert {:ok, [%{name: "interactive", status: :ready}]} = Jido.Console.Process.list(jido_home: root)

    stopper_script = "Jido.Console.main([\"stop\"])"

    assert {"jido: stopped interactive\n", 0} =
             System.cmd(
               mix,
               ["run", "--no-start", "--no-compile", "-e", stopper_script],
               cd: project,
               env: [{"MIX_ENV", "test"}, {"JIDO_HOME", root}],
               stderr_to_stdout: true
             )

    assert_receive {^owner, {:exit_status, owner_status}}, 5_000
    assert owner_status in [0, 1]
    assert {:ok, []} = Jido.Console.Process.list(jido_home: root)
  end

  test "formats TUI errors at the CLI boundary" do
    reasons = [
      {RuntimeError.exception("exception failure"), "internal error"},
      {"text failure", "internal error"},
      {{:bad, :reason}, "complete the request"}
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

  test "classifies command configuration and service failures" do
    unknown_provider =
      capture_io(:stderr, fn ->
        assert {:error, 64} =
                 Jido.Console.run(["auth", "status", "--provider", "missing"])
      end)

    assert unknown_provider =~ "unknown_provider"

    root = Path.join(System.tmp_dir!(), "jido-cli-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    env_file = Path.join(root, ".env")
    File.write!(env_file, "OPENAI_API_KEY=private\n")
    File.chmod!(env_file, 0o644)

    open_env =
      capture_io(:stderr, fn ->
        assert {:error, 64} =
                 Jido.Console.run(["auth", "status", "--env-file", env_file])
      end)

    assert open_env =~ "dotenv_permissions_too_open"

    home = Path.join(root, "broken-home")
    File.mkdir!(home)
    File.chmod!(home, 0o700)
    File.write!(Path.join(home, "run"), "not a directory")

    unavailable_store =
      capture_io(:stderr, fn ->
        assert {:error, 1} = Jido.Console.run(["status"], jido_home: home)
      end)

    assert unavailable_store =~ "process_store_unavailable"

    catalog_failure =
      capture_io(:stderr, fn ->
        assert {:error, 1} = Jido.Console.run(["models", "list"], model_policy: [])
      end)

    assert catalog_failure =~ "empty_model_policy"
  end

  defp count(text, value), do: length(String.split(text, value)) - 1

  defp index(text, value) do
    {index, _length} = :binary.match(text, value)
    index
  end

  defp await_port_output(port, expected, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_port_output(port, expected, deadline, "")
  end

  defp do_await_port_output(port, expected, deadline, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        output = output <> data

        if String.contains?(output, expected),
          do: output,
          else: do_await_port_output(port, expected, deadline, output)

      {^port, {:exit_status, status}} ->
        flunk("owner process exited with #{status} before readiness: #{output}")
    after
      remaining -> flunk("owner process did not become ready: #{output}")
    end
  end

  defp stop_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        _ = Jido.Console.Process.Tree.stop(os_pid)
        :ok

      nil ->
        :ok
    end
  end
end
