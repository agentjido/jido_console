defmodule Jido.Console.CodingTuiPtyTest do
  use ExUnit.Case, async: false

  alias CodingScenario.Oracle
  alias Jido.Console.Release.ProbeRuntime
  alias Jido.Console.Session.Server
  alias Jido.Console.Tui

  @expected_file Path.expand(
                   "../fixtures/coding/rate_limiter/v1/expected/lib/rate_limiter.ex.fixture",
                   __DIR__
                 )

  defmodule DriverAdapter do
    @behaviour Jido.Console.Terminal.Adapter

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

  test "drives the complete provider-free coding flow through the TUI", %{
    fixture: fixture,
    log: log
  } do
    test_pid = self()
    session_id = "coding-pty-#{System.unique_integer([:positive])}"

    task =
      Task.async(fn ->
        Tui.run(
          runtime: ProbeRuntime,
          runtime_startup: fn -> :ok end,
          coding_pack: :disabled,
          session_opts: workflow_session_opts(fixture.root, log),
          session_id: session_id,
          terminal_adapter: DriverAdapter,
          terminal_adapter_opts: [test_pid: test_pid, size: {100, 30}]
        )
      end)

    assert_receive {:coding_terminal_opened, owner, ref}, 10_000
    assert_frame("idle · Enter sends")

    send_event(owner, ref, {:paste, "Inspect the café λ source and tests."})
    send_event(owner, ref, {:key, :enter})
    inspect_frame = assert_frame("Inspected café λ source and tests.")
    assert inspect_frame =~ "coding.read"

    send_event(owner, ref, {:resize, 60, 18})
    resize_frame = assert_frame(["idle · Enter sends", "\e[18;3H"])
    assert resize_frame =~ " Jido · "
    assert resize_frame =~ "coding.restricted"
    assert resize_frame =~ "\e[K"
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

    {:ok, server} = Server.ensure_started(session_id)
    Server.stop(server)

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
end
