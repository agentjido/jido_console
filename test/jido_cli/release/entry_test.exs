defmodule Jido.Cli.Release.EntryTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Release.Entry

  test "dispatches a normal CLI invocation" do
    test_pid = self()

    assert 0 =
             Entry.run(["--version"],
               native_probe: nil,
               tui_probe: nil,
               cli_main: fn args -> send(test_pid, {:cli, args}) end
             )

    assert_receive {:cli, ["--version"]}
  end

  test "runs successful and failed native probes" do
    test_pid = self()

    common = [
      native_probe: "1",
      tui_probe: nil,
      ensure_all_started: fn :jido_cli -> {:ok, [:jido_cli]} end,
      output: fn message -> send(test_pid, {:output, message}) end,
      error_output: fn message -> send(test_pid, {:error, message}) end
    ]

    assert 0 =
             Entry.run(
               [],
               Keyword.put(common, :extract_from_bytes, fn _bytes ->
                 {:ok, %{content: "Jido native release probe."}}
               end)
             )

    assert_receive {:output, "jido release native probe passed"}

    assert 1 =
             Entry.run(
               [],
               Keyword.put(common, :extract_from_bytes, fn _bytes -> {:error, :fixture} end)
             )

    assert_receive {:error, message}
    assert message =~ "release native probe failed"
  end

  test "runs both TUI probe modes through injected boundaries" do
    test_pid = self()

    cli_run = fn args, opts ->
      send(test_pid, {:tui, args, opts})

      case Keyword.fetch!(opts, :runtime_startup).() do
        :ok -> :ok
        {:error, _reason} -> {:error, 1}
      end
    end

    common = [
      native_probe: nil,
      tui_probe_delay_ms: "12",
      sleep: fn delay -> send(test_pid, {:sleep, delay}) end,
      cli_run: cli_run
    ]

    assert 0 = Entry.run(["chat"], Keyword.put(common, :tui_probe, "success"))
    assert_receive {:sleep, 12}
    assert_receive {:tui, ["chat"], success_opts}
    assert success_opts[:runtime] == Jido.Cli.Release.ProbeRuntime
    assert success_opts[:coding_pack] == :disabled
    assert success_opts[:session_opts][:probe_mode] == :success

    workflow_opts =
      Keyword.merge(common,
        tui_probe: "workflow",
        probe_workspace: "/fixture/workspace",
        probe_expected: "/fixture/expected.ex",
        probe_log: "/fixture/workflow.jsonl"
      )

    assert 0 = Entry.run([], workflow_opts)
    assert_receive {:sleep, 12}
    assert_receive {:tui, [], workflow_tui_opts}

    assert workflow_tui_opts[:session_opts] == [
             probe_mode: :workflow,
             probe_workspace: "/fixture/workspace",
             probe_expected: "/fixture/expected.ex",
             probe_log: "/fixture/workflow.jsonl",
             probe_verifier: :mix_test
           ]

    private_opts = Keyword.put(workflow_opts, :probe_verifier, "private_runtime")
    assert 0 = Entry.run([], private_opts)
    assert_receive {:sleep, 12}
    assert_receive {:tui, [], private_tui_opts}
    assert private_tui_opts[:session_opts][:probe_verifier] == :private_runtime

    assert 1 = Entry.run([], Keyword.put(common, :tui_probe, "failure"))
    assert_receive {:sleep, 12}
  end

  test "rejects conflicting and invalid probe settings" do
    test_pid = self()
    output = fn message -> send(test_pid, {:error, message}) end

    assert 64 = Entry.run([], native_probe: "1", tui_probe: "success", error_output: output)
    assert_receive {:error, "jido: invalid release probe configuration"}

    assert 64 = Entry.run([], native_probe: nil, tui_probe: "other", error_output: output)
    assert_receive {:error, "jido: invalid release TUI probe mode"}
  end
end
