defmodule Jido.Cli.CodingTuiPtyTest do
  use ExUnit.Case, async: false

  alias CodingScenario.Oracle
  alias Jido.Cli.Release.ProbeRuntime
  alias Jido.Cli.Tui

  @project_root Path.expand("../..", __DIR__)
  @expected_file Path.expand(
                   "../fixtures/coding/rate_limiter/v1/expected/lib/rate_limiter.ex.fixture",
                   __DIR__
                 )

  defmodule DriverAdapter do
    @behaviour Jido.Cli.Terminal.Adapter

    @impl true
    def open(owner, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      ref = make_ref()
      handle = %{test_pid: test_pid, size: Keyword.get(opts, :size, {100, 30})}
      send(test_pid, {:coding_terminal_opened, owner, ref})
      {:ok, handle, ref, handle.size}
    end

    @impl true
    def write(handle, output) do
      send(handle.test_pid, {:coding_frame, IO.iodata_to_binary(output)})
      :ok
    end

    @impl true
    def size(handle), do: {:ok, handle.size}

    @impl true
    def close(handle) do
      send(handle.test_pid, :coding_terminal_closed)
      :ok
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "jido-coding-tui-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    fixture = Oracle.materialize!(Path.join(root, "repository"))
    log = Path.join(root, "workflow.jsonl")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, fixture: fixture, log: log}
  end

  defp build_executable! do
    build_root =
      Path.join(
        System.tmp_dir!(),
        "jido-compiled-pty-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(build_root)
    source_root = Path.join(build_root, "source")
    copy_project!(source_root)
    File.ln_s!(Path.join(@project_root, "deps"), Path.join(source_root, "deps"))
    executable = Path.join(source_root, "jido")

    {output, status} =
      System.cmd("mix", ["escript.build"],
        cd: source_root,
        env: [{"JIDO_CLI_JIDOKA_PATH", nil}, {"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    if status != 0 do
      raise "could not build the PTY test executable: #{output}"
    end

    on_exit(fn -> File.rm_rf!(build_root) end)
    executable
  end

  defp copy_project!(destination) do
    {paths, 0} =
      System.cmd("git", ["ls-files", "-co", "--exclude-standard", "-z"], cd: @project_root)

    paths
    |> String.split(<<0>>, trim: true)
    |> Enum.reject(&(&1 in ["_build", "deps", "jido"]))
    |> Enum.each(fn relative ->
      source = Path.join(@project_root, relative)

      if File.regular?(source) do
        target = Path.join(destination, relative)
        File.mkdir_p!(Path.dirname(target))
        File.cp!(source, target)
      end
    end)
  end

  test "drives the complete provider-free coding flow through the TUI", %{
    fixture: fixture,
    log: log
  } do
    test_pid = self()

    task =
      Task.async(fn ->
        Tui.run(
          runtime: ProbeRuntime,
          runtime_startup: fn -> :ok end,
          coding_pack: :disabled,
          session_opts: workflow_session_opts(fixture.root, log),
          terminal_adapter: DriverAdapter,
          terminal_adapter_opts: [test_pid: test_pid, size: {100, 30}]
        )
      end)

    assert_receive {:coding_terminal_opened, owner, ref}, 2_000
    assert_frame("idle · Enter sends")

    send_event(owner, ref, {:paste, "Inspect the café λ source and tests."})
    send_event(owner, ref, {:key, :enter})
    inspect_frame = assert_frame("Inspected café λ source and tests.")
    assert inspect_frame =~ "coding.read"

    send_event(owner, ref, {:resize, 60, 18})
    resize_frame = assert_frame(["idle · Enter sends", "\e[18;3H"])
    assert resize_frame =~ " Jido " <> String.duplicate("─", 54) <> "\e[K"
    assert resize_frame =~ "\e[18;3H"

    send_event(owner, ref, {:paste, "Implement the fixed-window rate limiter."})
    send_event(owner, ref, {:key, :enter})
    review_frame = assert_frame("Review required")
    assert review_frame =~ "[retried]"
    assert review_frame =~ "A approve · D deny"

    send_event(owner, ref, {:text, "a"})
    edit_frame = assert_frame("Implemented café λ rate limiter.")
    assert edit_frame =~ "[changed] lib/rate_limiter.ex"

    send_event(owner, ref, {:text, "Verify with mix test and review Git."})
    send_event(owner, ref, {:key, :enter})
    diff_frame = assert_frame("Verification passed. Repository review is ready.")
    assert diff_frame =~ "Git diff"
    assert diff_frame =~ "lib/rate_limiter.ex"

    send_event(owner, ref, {:text, "Cancel this turn."})
    send_event(owner, ref, {:key, :enter})
    cancel_frame = assert_frame("Cancellation fixture running…")
    assert cancel_frame =~ "running · Ctrl-C cancels"
    send_event(owner, ref, {:key, :ctrl_c})
    assert_frame("idle · Enter sends")

    send_event(owner, ref, {:key, :ctrl_c})
    assert :ok = Task.await(task, 5_000)
    assert_receive :coding_terminal_closed, 1_000

    assert_workflow_evidence(fixture, log)
  end

  @tag :expect
  test "drives the same coding flow through a compiled executable and real PTY", %{
    fixture: fixture,
    log: log
  } do
    expect = System.find_executable("expect") || flunk("expect is required for the PTY contract")
    executable = build_executable!()

    {output, status} =
      System.cmd(expect, ["-c", expect_script()],
        cd: fixture.root,
        env: [
          {"JIDO_BIN", executable},
          {"JIDO_RELEASE_TUI_PROBE", "workflow"},
          {"JIDO_RELEASE_TUI_PROBE_DELAY_MS", "25"},
          {"JIDO_RELEASE_TUI_PROBE_WORKSPACE", fixture.root},
          {"JIDO_RELEASE_TUI_PROBE_EXPECTED", @expected_file},
          {"JIDO_RELEASE_TUI_PROBE_LOG", log},
          {"LANG", "en_US.UTF-8"},
          {"LC_ALL", "en_US.UTF-8"},
          {"TERM", "xterm-256color"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "workflow=passed"
    refute output =~ "BREAK:"
    assert_workflow_evidence(fixture, log)
  end

  defp workflow_session_opts(workspace, log) do
    [
      probe_mode: :workflow,
      probe_workspace: workspace,
      probe_expected: @expected_file,
      probe_log: log
    ]
  end

  defp send_event(owner, ref, event), do: send(owner, {:jido_terminal, ref, event})

  defp assert_frame(expected, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_frame(List.wrap(expected), deadline, "")
  end

  defp await_frame(expected_parts, deadline, latest) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:coding_frame, frame} ->
        if Enum.all?(expected_parts, &String.contains?(frame, &1)),
          do: frame,
          else: await_frame(expected_parts, deadline, frame)
    after
      remaining ->
        flunk("frame did not contain #{inspect(expected_parts)}; latest frame: #{inspect(latest)}")
    end
  end

  defp assert_workflow_evidence(fixture, log) do
    records =
      log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert records |> Enum.filter(&(&1["event"] == "turn_started")) |> length() == 4
    assert Enum.any?(records, &(&1["prompt"] == "Inspect the café λ source and tests."))
    assert Enum.any?(records, &(&1 == %{"event" => "review", "decision" => "approved"}))
    assert Enum.any?(records, &(&1["event"] == "turn_cancelled"))
    assert List.last(records) == %{"event" => "session_closed"}

    operations =
      records
      |> Enum.filter(&(&1["event"] == "operation"))
      |> Enum.map(& &1["operation"])

    assert operations == Oracle.valid_operations(fixture.scenario)

    assert {:ok, evidence} =
             Oracle.verify(fixture, operations, Oracle.expected_claims(fixture))

    assert evidence["verification"]["status"] == "passed"
    assert evidence["changed_paths"] == ["lib/rate_limiter.ex"]
  end

  defp expect_script do
    """
    encoding system utf-8
    set timeout 45
    set stty_init "rows 30 columns 100"
    log_user 0
    spawn -noecho $env(JIDO_BIN)

    expect {
      -re {idle .* Enter sends} {}
      timeout {puts "missing initial idle frame"; exit 2}
      eof {puts "early executable exit"; exit 3}
    }
    stty -isig < $spawn_out(slave,name)

    send "\\033\\[200~Inspect the café λ source and tests.\\033\\[201~\\r"
    expect {
      -re {coding\.read} {}
      timeout {puts "missing inspection tool activity"; exit 4}
    }
    expect {
      -re {Inspected café λ source and tests\.} {}
      timeout {puts "missing Unicode inspection result"; exit 5}
    }

    stty rows 18 columns 60 < $spawn_out(slave,name)
    expect {
      -exact "\\033\\[18;3H" {}
      timeout {puts "missing resized frame"; exit 6}
    }
    send "\\033\\[200~Implement the fixed-window rate limiter.\\033\\[201~\\r"
    expect {
      -re {\[retried\]} {}
      timeout {puts "missing retry activity"; exit 7}
    }
    expect {
      -re {Review required} {}
      timeout {puts "missing approval review"; exit 8}
    }
    send "a"
    expect {
      -re {Implemented café λ rate limiter\.} {}
      timeout {puts "missing approved result"; exit 9}
    }

    send "Verify with mix test and review Git.\\r"
    expect {
      -re {Verification passed\. Repository review is ready\.} {}
      timeout {puts "missing verification result"; exit 10}
    }
    expect {
      -re {Git diff} {}
      timeout {puts "missing Git review"; exit 11}
    }
    expect {
      -re {idle .* Enter sends} {}
      timeout {puts "missing idle state after verification"; exit 12}
    }

    send "Cancel this turn.\\r"
    expect {
      -re {Cancellation fixture running} {}
      timeout {puts "missing cancellation turn"; exit 13}
    }
    expect {
      -re {running .* Ctrl-C cancels} {}
      timeout {puts "missing cancellable running state"; exit 14}
    }

    send "\\003"
    expect {
      -re {idle .* Enter sends} {}
      -re {BREAK:} {puts "Erlang break menu opened"; exit 15}
      timeout {puts "missing idle state after cancellation"; exit 16}
    }

    send "\\033"
    expect {
      -exact "\\033\\[?2004l\\033\\[0m\\033\\[?25h\\033\\[?1049l" {}
      -re {BREAK:} {puts "Erlang break menu opened"; exit 17}
      timeout {puts "missing terminal cleanup"; exit 18}
    }
    expect eof
    set wait_result [wait]
    if {[llength $wait_result] != 4 || [lindex $wait_result 2] != 0 || [lindex $wait_result 3] != 0} {
      puts "executable failed: $wait_result"
      exit 19
    }
    puts "workflow=passed"
    """
  end
end
