defmodule Jido.Cli.TuiTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Tui
  alias Jidoka.Cancellation
  alias Jidoka.Event

  defmodule FakeAdapter do
    @behaviour Jido.Terminal.Adapter

    @impl true
    def open(owner, opts) do
      ref = make_ref()
      test_pid = Keyword.fetch!(opts, :test_pid)
      {:ok, writes} = Agent.start_link(fn -> 0 end)

      handle = %{
        test_pid: test_pid,
        owner: owner,
        ref: ref,
        fail_write?: Keyword.get(opts, :fail_write?, false),
        fail_after: Keyword.get(opts, :fail_after),
        writes: writes
      }

      send(test_pid, {:terminal_opened, owner, ref})
      {:ok, handle, ref, {40, 10}}
    end

    @impl true
    def write(%{fail_write?: true}, _output), do: {:error, :draw_failed}

    def write(handle, output) do
      count = Agent.get_and_update(handle.writes, &{&1, &1 + 1})

      if is_integer(handle.fail_after) and count >= handle.fail_after do
        {:error, :draw_failed}
      else
        send(handle.test_pid, {:frame, IO.iodata_to_binary(output)})
        :ok
      end
    end

    @impl true
    def size(_handle), do: {:ok, {40, 10}}

    @impl true
    def close(handle) do
      send(handle.test_pid, :terminal_closed)
      if Process.alive?(handle.writes), do: Agent.stop(handle.writes)
      :ok
    end
  end

  defmodule FakeRuntime do
    @behaviour Jido.Cli.Runtime

    @impl true
    def start_session(Jido.Cli.DefaultAgent, opts) do
      send(Keyword.fetch!(opts, :test_pid), :session_started)
      {:ok, :session}
    end

    @impl true
    def start_turn(:session, prompt, owner, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :turn_started)
      send(test_pid, {:turn_prompt, prompt, Keyword.get(opts, :context)})
      request = %{request_id: "request-1", test_pid: test_pid, prompt: prompt}

      delta =
        Event.build(:llm_delta, [],
          request_id: request.request_id,
          data: %{chunk_type: :content, delta: "Hello"}
        )

      send(owner, {:jidoka_turn_event, delta})

      send(
        owner,
        {:jidoka_turn_event, Event.build(:turn_finished, [delta], request_id: request.request_id)}
      )

      {:ok, request}
    end

    @impl true
    def await(request, opts) do
      send(request.test_pid, {:turn_awaited, opts})

      if request.prompt == "review edit" do
        {:ok, :next_session, "Edit complete.",
         [
           %{
             "kind" => "edit",
             "path" => "lib/value.ex",
             "action" => "edit",
             "status" => "changed",
             "before_sha256" => "sha256:" <> String.duplicate("1", 64),
             "after_sha256" => "sha256:" <> String.duplicate("2", 64),
             "checkpoint" => %{"checkpoint_ref" => "check-1"},
             "diff" => %{
               "before_lines" => 4,
               "after_lines" => 5,
               "changed_before_lines" => 1,
               "changed_after_lines" => 2
             }
           }
         ]}
      else
        {:ok, :next_session, "Hello back"}
      end
    end

    @impl true
    def cancel(request, _opts), do: {:ok, cancellation(request.request_id)}

    defp cancellation(request_id) do
      Cancellation.new!(request_id: request_id, cancelled_at_ms: 0)
    end
  end

  defmodule FailureRuntime do
    @behaviour Jido.Cli.Runtime

    @impl true
    def start_session(Jido.Cli.DefaultAgent, opts) do
      send(Keyword.fetch!(opts, :test_pid), :failure_session_started)
      {:ok, :session}
    end

    @impl true
    def start_turn(:session, "hello", owner, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      mode = Keyword.fetch!(opts, :mode)
      send(test_pid, {:failure_turn_started, mode})

      if mode == :start_error do
        {:error, :start_failed}
      else
        request = %{request_id: "failure-request", mode: mode, owner: owner, test_pid: test_pid}

        if mode in [:await_raise, :await_throw] do
          event = Event.build(:turn_finished, [], request_id: request.request_id)
          send(owner, {:jidoka_turn_event, event})
        end

        {:ok, request}
      end
    end

    @impl true
    def await(%{mode: :await_raise}, _opts), do: raise("await raised")
    def await(%{mode: :await_throw}, _opts), do: throw(:await_thrown)

    def await(%{mode: :already_finished} = request, opts) do
      send(request.test_pid, {:turn_awaited, opts})
      {:ok, :next_session, "completed"}
    end

    def await(request, _opts), do: {:cancelled, cancellation(request.request_id)}

    @impl true
    def cancel(%{mode: :cancel_ok} = request, _opts) do
      send(request.test_pid, {:cancel_called, :cancel_ok})
      {:ok, cancellation(request.request_id)}
    end

    def cancel(%{mode: :cancel_error} = request, _opts) do
      send(request.test_pid, {:cancel_called, :cancel_error})
      {:error, :cancel_failed}
    end

    def cancel(%{mode: :already_finished} = request, _opts) do
      terminal = Event.build(:turn_finished, [], request_id: request.request_id)
      send(request.owner, {:jidoka_turn_event, terminal})
      send(request.test_pid, {:cancel_called, :already_finished})
      {:error, :request_already_finished}
    end

    defp cancellation(request_id) do
      Cancellation.new!(request_id: request_id, cancelled_at_ms: 0)
    end
  end

  test "runs one complete streamed turn through injected boundaries" do
    test_pid = self()

    task =
      Task.async(fn ->
        Tui.run(
          runtime: FakeRuntime,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          session_opts: [test_pid: test_pid],
          turn_opts: [test_pid: test_pid]
        )
      end)

    assert_receive :session_started
    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, initial_frame}
    assert initial_frame =~ "Jido"
    send(owner, :unrelated_message)

    send(owner, {:jido_terminal, ref, {:text, "hello"}})
    send(owner, {:jido_terminal, ref, {:key, :enter}})
    assert_receive :turn_started
    assert_receive {:turn_prompt, "hello", %{"coding" => %{"pack_id" => "jido.coding_pack"}}}
    assert_receive {:turn_awaited, await_opts}
    assert await_opts[:timeout] == 30_000
    assert await_opts[:cancel_on_timeout] == false

    assert_frame_contains("Hello back")

    send(owner, {:jido_terminal, ref, {:key, :escape}})
    assert :ok = Task.await(task)
    assert_receive :terminal_closed
  end

  test "shows bounded coding review returned by the runtime" do
    test_pid = self()

    task =
      Task.async(fn ->
        Tui.run(
          runtime: FakeRuntime,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          session_opts: [test_pid: test_pid],
          turn_opts: [test_pid: test_pid]
        )
      end)

    assert_receive :session_started
    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _initial_frame}

    send(owner, {:jido_terminal, ref, {:text, "review edit"}})
    send(owner, {:jido_terminal, ref, {:key, :enter}})
    assert_receive :turn_started
    assert_receive {:turn_awaited, _opts}

    frame = assert_frame_contains("[changed] lib/value.ex")
    assert frame =~ "checkpoint check-1"
    assert frame =~ "changed -1 +2"

    send(owner, {:jido_terminal, ref, {:key, :escape}})
    assert :ok = Task.await(task)
    assert_receive :terminal_closed
  end

  test "shows instruction provenance and attaches resolved file context" do
    root = Path.join(System.tmp_dir!(), "jido-tui-coding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "AGENTS.md"), "project rules")
    File.write!(Path.join(root, "value.ex"), "defmodule Value do\nend\n")
    test_pid = self()

    task =
      Task.async(fn ->
        Tui.run(
          runtime: FakeRuntime,
          project_root: root,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          session_opts: [test_pid: test_pid],
          turn_opts: [test_pid: test_pid]
        )
      end)

    assert_receive :session_started
    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, frame}
    assert frame =~ "Loaded AGENTS.md"

    send(owner, {:jido_terminal, ref, {:text, "Review @value.ex"}})
    send(owner, {:jido_terminal, ref, {:key, :enter}})
    assert_receive :turn_started

    assert_receive {:turn_prompt, "Review value.ex",
                    %{"coding" => %{"files" => [%{"path" => "value.ex", "content" => content}]}}}

    assert content =~ "defmodule Value"
    assert_receive {:turn_awaited, _opts}
    send(owner, {:jido_terminal, ref, {:key, :escape}})
    assert :ok = Task.await(task)
    File.rm_rf!(root)
  end

  test "closes the terminal when the first draw fails" do
    assert {:error, :draw_failed} =
             Tui.run(
               runtime: FakeRuntime,
               terminal_adapter: FakeAdapter,
               terminal_adapter_opts: [test_pid: self(), fail_write?: true],
               session_opts: [test_pid: self()]
             )

    assert_receive :session_started
    assert_receive {:terminal_opened, _owner, _ref}
    assert_receive :terminal_closed
  end

  test "returns an error when a scheduled redraw fails" do
    test_pid = self()

    task =
      Task.async(fn ->
        Tui.run(
          runtime: FakeRuntime,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid, fail_after: 1],
          session_opts: [test_pid: test_pid]
        )
      end)

    assert_receive :session_started
    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _initial_frame}
    send(owner, {:jido_terminal, ref, {:text, "change"}})
    assert {:error, :draw_failed} = Task.await(task, 500)
    assert_receive :terminal_closed
  end

  test "shows a start-turn error and remains usable" do
    {task, owner, ref} = start_failure_tui(:start_error)
    send_prompt(owner, ref)
    assert_receive {:failure_turn_started, :start_error}
    assert_frame_contains("error ·")
    stop_tui(task, owner, ref)
  end

  test "handles successful and failed cancellation" do
    {task, owner, ref} = start_failure_tui(:cancel_ok)
    send_prompt(owner, ref)
    assert_receive {:failure_turn_started, :cancel_ok}
    send(owner, {:jido_terminal, ref, {:key, :ctrl_c}})
    assert_receive {:cancel_called, :cancel_ok}
    assert_frame_contains("idle ·")
    stop_tui(task, owner, ref)

    {task, owner, ref} = start_failure_tui(:cancel_error)
    send_prompt(owner, ref)
    assert_receive {:failure_turn_started, :cancel_error}
    send(owner, {:jido_terminal, ref, {:key, :ctrl_c}})
    assert_receive {:cancel_called, :cancel_error}
    assert_frame_contains("error · :cancel_failed")
    stop_tui(task, owner, ref)
  end

  test "keeps the completed answer when completion wins cancellation" do
    {task, owner, ref} = start_failure_tui(:already_finished)
    send_prompt(owner, ref)
    assert_receive {:failure_turn_started, :already_finished}

    send(owner, {:jido_terminal, ref, {:key, :ctrl_c}})
    assert_receive {:cancel_called, :already_finished}
    assert_receive {:turn_awaited, _opts}

    frame = assert_frame_contains("completed")
    assert frame =~ "idle ·"
    refute frame =~ "request_already_finished"
    refute frame =~ "error ·"

    stop_tui(task, owner, ref)
  end

  test "converts await exceptions and throws to turn errors" do
    for mode <- [:await_raise, :await_throw] do
      {task, owner, ref} = start_failure_tui(mode)
      send_prompt(owner, ref)
      assert_receive {:failure_turn_started, ^mode}
      assert_frame_contains("error ·")
      stop_tui(task, owner, ref)
    end
  end

  defp start_failure_tui(mode) do
    test_pid = self()

    task =
      Task.async(fn ->
        Tui.run(
          runtime: FailureRuntime,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          session_opts: [test_pid: test_pid],
          turn_opts: [test_pid: test_pid, mode: mode]
        )
      end)

    assert_receive :failure_session_started
    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _initial_frame}
    {task, owner, ref}
  end

  defp send_prompt(owner, ref) do
    send(owner, {:jido_terminal, ref, {:text, "hello"}})
    send(owner, {:jido_terminal, ref, {:key, :enter}})
  end

  defp stop_tui(task, owner, ref) do
    send(owner, {:jido_terminal, ref, {:key, :escape}})
    assert :ok = Task.await(task, 500)
    assert_receive :terminal_closed
  end

  defp assert_frame_contains(content, timeout \\ 500) do
    started_at = System.monotonic_time(:millisecond)
    receive_frame_with(content, started_at, timeout)
  end

  defp receive_frame_with(content, started_at, timeout) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    remaining = max(timeout - elapsed, 0)

    receive do
      {:frame, frame} ->
        if frame =~ content do
          frame
        else
          receive_frame_with(content, started_at, timeout)
        end
    after
      remaining -> flunk("no frame contained #{inspect(content)}")
    end
  end
end
