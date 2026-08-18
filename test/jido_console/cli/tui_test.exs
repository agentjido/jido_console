defmodule Jido.Console.TuiTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Runtime.Result
  alias Jido.Console.Session.Server
  alias Jido.Console.Tui
  alias Jidoka.Cancellation
  alias Jidoka.Event

  defmodule FakeAdapter do
    @behaviour Jido.Console.Terminal.Adapter

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
        fail_control: Keyword.get(opts, :fail_control),
        writes: writes
      }

      send(test_pid, {:terminal_opened, owner, ref})
      {:ok, handle, ref, {40, 10}}
    end

    @impl true
    def write(%{fail_write?: true}, _output), do: {:error, :draw_failed}

    def write(handle, output) do
      count = Agent.get_and_update(handle.writes, &{&1, &1 + 1})
      controlled_failure? = if handle.fail_control, do: Agent.get(handle.fail_control, & &1), else: false

      if controlled_failure? or (is_integer(handle.fail_after) and count >= handle.fail_after) do
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
    @behaviour Jido.Console.Runtime

    @impl true
    def start_session(Jido.Console.DefaultAgent, opts) do
      send(Keyword.fetch!(opts, :test_pid), :session_started)
      spec = Keyword.get(opts, :agent_spec_override)
      model = if spec, do: Jidoka.Config.model_ref(spec.model)
      send(Keyword.fetch!(opts, :test_pid), {:session_model, model})
      {:ok, :session}
    end

    @impl true
    def start_turn(session, prompt, owner, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :turn_started)
      send(test_pid, {:turn_prompt, prompt, Keyword.get(opts, :context)})
      request = %{request_id: "request-1", test_pid: test_pid, prompt: prompt, session: session}

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

      case request.prompt do
        "early stream" ->
          send(request.test_pid, {:await_blocked, self()})

          receive do
            :release_await -> Result.ok(request.request_id, :next_session, request, "Hello back")
          end

        "review edit" ->
          Result.ok(request.request_id, :next_session, request, "Edit complete.",
            coding_review_candidates: [
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
            ]
          )

        _other ->
          Result.ok(request.request_id, :next_session, request, "Hello back")
      end
    end

    @impl true
    def cancel(request, _opts), do: {:ok, cancellation(request.request_id)}

    defp cancellation(request_id) do
      Cancellation.new!(request_id: request_id, cancelled_at_ms: 0)
    end
  end

  defmodule FailureRuntime do
    @behaviour Jido.Console.Runtime

    @impl true
    def start_session(Jido.Console.DefaultAgent, opts) do
      send(Keyword.fetch!(opts, :test_pid), :failure_session_started)
      {:ok, :session}
    end

    @impl true
    def start_turn(:session, "hello", owner, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      mode = Keyword.fetch!(opts, :mode)
      send(test_pid, {:failure_turn_started, mode})

      if mode == :blocking_start do
        send(test_pid, {:start_turn_blocked, self()})

        receive do
          :release_start_turn -> :ok
        end
      end

      if mode == :start_error do
        {:error, :start_failed}
      else
        controller =
          if mode in [:cancel_ok, :cancel_error, :blocking_cancel, :already_finished] do
            spawn(fn -> controller_loop(Process.monitor(test_pid), nil) end)
          end

        request = %{
          request_id: "failure-request",
          mode: mode,
          owner: owner,
          test_pid: test_pid,
          controller: controller,
          session: :session
        }

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
      await_controller(request.controller)
    end

    def await(%{mode: mode} = request, _opts) when mode in [:cancel_ok, :cancel_error] do
      await_controller(request.controller)
    end

    def await(%{mode: :blocking_cancel} = request, _opts), do: await_controller(request.controller)

    def await(%{mode: :no_terminal} = request, _opts),
      do: Result.ok(request.request_id, :next_session, request, "completed without terminal event")

    def await(request, _opts) do
      cancellation = cancellation(request.request_id)
      Result.cancelled(request.request_id, request.session, request, cancellation)
    end

    @impl true
    def cancel(%{mode: :cancel_ok} = request, _opts) do
      send(request.test_pid, {:cancel_called, :cancel_ok})
      cancellation = cancellation(request.request_id)

      send(
        request.controller,
        {:complete, Result.cancelled(request.request_id, request.session, request, cancellation)}
      )

      {:ok, cancellation}
    end

    def cancel(%{mode: :cancel_error} = request, _opts) do
      send(request.test_pid, {:cancel_called, :cancel_error})
      {:error, :cancel_failed}
    end

    def cancel(%{mode: :blocking_cancel} = request, _opts) do
      send(request.test_pid, {:cancel_blocked, self()})

      receive do
        :release_cancel -> :ok
      end

      cancellation = cancellation(request.request_id)

      send(
        request.controller,
        {:complete, Result.cancelled(request.request_id, request.session, request, cancellation)}
      )

      {:ok, cancellation}
    end

    def cancel(%{mode: :already_finished} = request, _opts) do
      terminal = Event.build(:turn_finished, [], request_id: request.request_id)
      send(request.owner, {:jidoka_turn_event, terminal})
      send(request.test_pid, {:cancel_called, :already_finished})

      send(
        request.controller,
        {:complete, Result.ok(request.request_id, :next_session, request, "completed")}
      )

      {:error, :request_already_finished}
    end

    defp await_controller(controller) do
      send(controller, {:register, self()})

      receive do
        {:complete, result} -> result
      after
        5_000 -> {:error, :fake_await_timeout}
      end
    end

    defp controller_loop(test_ref, await_pid) do
      receive do
        {:register, pid} when is_tuple(await_pid) ->
          {:pending, result} = await_pid
          send(pid, {:complete, result})

        {:register, pid} ->
          controller_loop(test_ref, pid)

        {:complete, result} when is_pid(await_pid) ->
          send(await_pid, {:complete, result})

        {:complete, result} ->
          controller_loop(test_ref, {:pending, result})

        {:DOWN, ^test_ref, :process, _pid, _reason} ->
          :ok
      end
    end

    defp cancellation(request_id) do
      Cancellation.new!(request_id: request_id, cancelled_at_ms: 0)
    end
  end

  defmodule CloseRuntime do
    @behaviour Jido.Console.Runtime

    @impl true
    def start_session(Jido.Console.DefaultAgent, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :close_session_started)
      {:ok, {:close_session, test_pid}}
    end

    @impl true
    def start_turn(_session, _prompt, _owner, _opts), do: {:error, :not_supported}

    @impl true
    def await(_request, _opts), do: {:error, :not_supported}

    @impl true
    def cancel(_request, _opts), do: {:error, :not_supported}

    @impl true
    def close_session({:close_session, test_pid}) do
      send(test_pid, :runtime_session_closed)
      :ok
    end
  end

  defmodule OwnerBoundRuntime do
    @behaviour Jido.Console.Runtime

    @impl true
    def start_session(Jido.Console.DefaultAgent, _opts), do: {:ok, :owner_bound_session}

    @impl true
    def start_turn(:owner_bound_session, _prompt, _relay, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      request_owner = self()
      controller = spawn(fn -> controller_loop(Process.monitor(request_owner)) end)
      send(test_pid, {:owner_bound_request, request_owner, controller})
      {:ok, %{request_id: "owner-bound-request", controller: controller, session: :owner_bound_session}}
    end

    @impl true
    def await(request, _opts) do
      send(request.controller, {:await, self()})

      receive do
        {:owner_bound_result, result} -> result
      after
        100 -> {:error, :request_expired}
      end
    end

    @impl true
    def cancel(_request, _opts), do: {:error, :request_already_finished}

    defp controller_loop(owner_ref) do
      receive do
        {:await, caller} ->
          request = %{
            request_id: "owner-bound-request",
            controller: self(),
            session: :owner_bound_session
          }

          send(
            caller,
            {:owner_bound_result, Result.ok(request.request_id, :next_session, request, "owner kept result")}
          )

          controller_loop(owner_ref)

        {:DOWN, ^owner_ref, :process, _owner, _reason} ->
          :ok
      end
    end
  end

  defmodule ShutdownRuntime do
    @behaviour Jido.Console.Runtime

    @impl true
    def start_session(Jido.Console.DefaultAgent, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:shutdown_session_opened, self()})
      {:ok, {:shutdown_session, test_pid, Keyword.get(opts, :shutdown_mode, :normal)}}
    end

    @impl true
    def start_turn({:shutdown_session, test_pid, mode}, prompt, relay, _opts) do
      controller = spawn(fn -> shutdown_controller(test_pid, Process.monitor(relay), nil, false) end)

      request = %{
        request_id: "shutdown-request",
        test_pid: test_pid,
        controller: controller,
        mode: mode,
        session: {:shutdown_session, test_pid, mode}
      }

      send(test_pid, {:shutdown_turn_started, self(), relay, controller, prompt})
      {:ok, request}
    end

    @impl true
    def await(request, _opts) do
      send(request.test_pid, {:shutdown_await_started, self()})
      send(request.controller, {:await, self()})

      receive do
        :shutdown_cancelled ->
          send(request.test_pid, {:shutdown_terminal_result, self()})

          cancellation = Cancellation.new!(request_id: request.request_id, cancelled_at_ms: 0)
          Result.cancelled(request.request_id, request.session, request, cancellation)
      end
    end

    @impl true
    def cancel(%{mode: :block_cancel} = request, _opts) do
      send(request.test_pid, {:shutdown_cancel_blocked, self()})
      receive do: (:never -> {:error, :never})
    end

    def cancel(request, _opts) do
      send(request.test_pid, {:shutdown_cancel_called, self()})
      send(request.controller, :cancel)
      {:ok, Cancellation.new!(request_id: request.request_id, cancelled_at_ms: 0)}
    end

    @impl true
    def close_session({:shutdown_session, test_pid, _mode}) do
      send(test_pid, {:shutdown_session_closed, self()})
      :ok
    end

    defp shutdown_controller(test_pid, relay_ref, await_pid, cancelled?) do
      receive do
        {:await, pid} ->
          if cancelled? do
            send(pid, :shutdown_cancelled)
            send(test_pid, {:shutdown_controller_closed, self()})
          else
            shutdown_controller(test_pid, relay_ref, pid, false)
          end

        :cancel ->
          if is_pid(await_pid) do
            send(await_pid, :shutdown_cancelled)
            send(test_pid, {:shutdown_controller_closed, self()})
          else
            shutdown_controller(test_pid, relay_ref, nil, true)
          end

        {:DOWN, ^relay_ref, :process, _relay, _reason} ->
          send(test_pid, {:shutdown_controller_closed, self()})
      end
    end
  end

  defmodule ApprovalRuntime do
    @behaviour Jido.Console.Runtime

    @impl true
    def start_session(Jido.Console.DefaultAgent, opts) do
      send(Keyword.fetch!(opts, :test_pid), :approval_session_started)
      {:ok, :approval_session}
    end

    @impl true
    def start_turn(:approval_session, prompt, _owner, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :approval_turn_started)

      {:ok,
       %{
         request_id: "approval-request",
         prompt: prompt,
         test_pid: test_pid,
         session: :approval_session
       }}
    end

    @impl true
    def await(request, _opts) do
      review = %{
        interrupt_id: "review-1",
        operation: "write_file",
        arguments: %{"path" => "\e[31mlib/value.ex\e[0m"},
        reason: :manual,
        expires_at_ms: 30_000
      }

      Result.pending_review(request.request_id, request.session, request, [review])
    end

    @impl true
    def approve(%Result{outcome: %Result.PendingReview{}} = result, review, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:approval_called, review.interrupt_id})
      emit_tool_timeline(Keyword.fetch!(opts, :stream_to), result.request_id)

      Result.ok(
        result.request_id,
        :approved_session,
        result.handle,
        "Approved change complete.",
        approval: :approved
      )
    end

    @impl true
    def deny(%Result{} = result, _review, _opts),
      do: Result.error(result.request_id, result.session, result.handle, :review_denied, approval: :denied)

    @impl true
    def cancel(request, _opts), do: {:ok, Cancellation.new!(request_id: request.request_id, cancelled_at_ms: 0)}

    defp emit_tool_timeline(stream_to, request_id) do
      planned =
        Event.build(:effect_planned, [],
          request_id: request_id,
          seq: 0,
          effect_id: "write-1",
          effect_kind: :operation,
          operation: "write_file"
        )

      completed =
        Event.build(:effect_completed, [],
          request_id: request_id,
          seq: 1,
          effect_id: "write-1",
          effect_kind: :operation,
          operation: "write_file"
        )

      terminal = Event.build(:turn_finished, [], request_id: request_id, seq: 2)

      for event <- [planned, completed, terminal] do
        send(stream_to, {:jidoka_turn_event, event})
      end
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

    assert_receive :session_started, 10_000
    assert_receive {:session_model, _model}, 2_000
    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, initial_frame}
    assert initial_frame =~ "Jido"
    send(owner, :unrelated_message)

    send(owner, {:jido_terminal, ref, {:text, "hello"}})
    send(owner, {:jido_terminal, ref, {:key, :enter}})
    assert_receive :turn_started
    assert_receive {:turn_prompt, "hello", %{"coding" => %{"pack_id" => "jido.coding_pack"}}}
    assert_receive {:turn_awaited, await_opts}
    assert await_opts[:timeout] in [30_000, 180_000]
    assert await_opts[:cancel_on_timeout] == false

    assert_frame_contains("Hello back")

    send(owner, {:jido_terminal, ref, {:key, :escape}})
    assert :ok = Task.await(task)
    assert_receive :terminal_closed
  end

  test "completes a bounded 20-turn streamed session and closes its resources" do
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

    assert_receive :session_started, 10_000
    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _initial_frame}

    for index <- 1..20 do
      prompt = "hello #{index}"
      flush_frames()
      send(owner, {:jido_terminal, ref, {:text, prompt}})
      send(owner, {:jido_terminal, ref, {:key, :enter}})
      assert_receive :turn_started, 2_000
      assert_receive {:turn_prompt, ^prompt, _context}, 2_000
      assert_receive {:turn_awaited, _opts}, 2_000
      assert_frame_contains_all([prompt, "Hello back", "idle ·"], 2_000)
    end

    stop_tui(task, owner, ref)
  end

  test "applies /model to a new runtime session" do
    test_pid = self()
    root = Path.join(System.tmp_dir!(), "jido-tui-model-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    catalog = [
      %{identity: "openai:gpt-4.1-mini", provider: "openai", model: "gpt-4.1-mini", tier: :supported},
      %{identity: "ollama:llama3.2", provider: "ollama", model: "llama3.2", tier: :beta}
    ]

    task =
      Task.async(fn ->
        Tui.run(
          runtime: FakeRuntime,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          session_opts: [test_pid: test_pid],
          turn_opts: [test_pid: test_pid],
          project_root: root,
          jido_home: Path.join(root, "home"),
          catalog_entries: catalog,
          model: "openai:gpt-4.1-mini"
        )
      end)

    assert_receive :session_started, 10_000
    assert_receive {:session_model, "openai:gpt-4.1-mini"}, 2_000
    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _initial_frame}

    send(owner, {:jido_terminal, ref, {:text, "/model ollama:llama3.2"}})
    send(owner, {:jido_terminal, ref, {:key, :enter}})
    assert_receive :session_started, 10_000
    assert_receive {:session_model, "ollama:llama3.2"}, 2_000
    assert_frame_contains("Selected ollama:llama3.2")

    stop_tui(task, owner, ref)
  end

  test "uses the visible catalog default when the coding pack is disabled" do
    test_pid = self()

    catalog = [
      %{identity: "openai:gpt-4.1-mini", provider: "openai", model: "gpt-4.1-mini", tier: :supported}
    ]

    task =
      Task.async(fn ->
        Tui.run(
          runtime: FakeRuntime,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          session_opts: [test_pid: test_pid],
          turn_opts: [test_pid: test_pid],
          catalog_entries: catalog,
          coding_pack: :disabled
        )
      end)

    assert_receive :session_started, 10_000
    assert_receive {:session_model, "openai:gpt-4.1-mini"}, 2_000
    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _initial_frame}

    stop_tui(task, owner, ref)
  end

  test "keeps the Jidoka request owner alive while it awaits the result" do
    test_pid = self()
    session_id = "owner-bound-#{System.unique_integer([:positive])}"

    task =
      Task.async(fn ->
        Tui.run(
          runtime: OwnerBoundRuntime,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          turn_opts: [test_pid: test_pid],
          session_id: session_id
        )
      end)

    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _initial_frame}
    send_prompt(owner, ref)
    assert_receive {:owner_bound_request, request_owner, controller}
    assert Process.alive?(request_owner)
    assert_frame_contains("owner kept result")

    stop_tui(task, owner, ref)
    assert Process.alive?(request_owner)
    assert Process.alive?(controller)
    controller_ref = Process.monitor(controller)
    Server.stop(request_owner)
    refute Process.alive?(request_owner)
    assert_receive {:DOWN, ^controller_ref, :process, ^controller, :normal}, 500
    refute Process.alive?(controller)
  end

  test "buffers stream events until the asynchronous request is installed" do
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

    assert_receive :session_started, 10_000
    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _initial_frame}
    send(owner, {:jido_terminal, ref, {:text, "early stream"}})
    send(owner, {:jido_terminal, ref, {:key, :enter}})
    assert_receive {:await_blocked, worker}
    assert_frame_contains("Hello")

    send(worker, :release_await)
    assert_frame_contains("Hello back")
    stop_tui(task, owner, ref)
  end

  test "draws first and queues a prompt while the runtime starts" do
    test_pid = self()

    task =
      Task.async(fn ->
        Tui.run(
          runtime: FakeRuntime,
          application_startup: fn ->
            send(test_pid, {:application_starting, self()})

            receive do
              :release_application -> :ok
            end
          end,
          runtime_startup: fn ->
            send(test_pid, {:runtime_starting, self()})

            receive do
              :release_runtime -> :ok
            end
          end,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          session_opts: [test_pid: test_pid],
          turn_opts: [test_pid: test_pid]
        )
      end)

    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, first_frame}
    assert first_frame =~ "starting runtime · Enter queues"
    assert_receive {:application_starting, ^owner}

    send(owner, {:jido_terminal, ref, {:text, "hello"}})
    send(owner, {:jido_terminal, ref, {:key, :enter}})
    send(owner, :release_application)

    assert_receive {:runtime_starting, startup_pid}
    refute_receive :session_started, 50

    assert_frame_contains("starting runtime · prompt queued")
    refute_receive :turn_started, 50

    send(startup_pid, :release_runtime)
    assert_receive :session_started, 1_000
    assert_receive :turn_started, 1_000
    assert_receive {:turn_prompt, "hello", %{"coding" => %{"pack_id" => "jido.coding_pack"}}}, 1_000
    assert_receive {:turn_awaited, _await_opts}, 1_000
    assert_frame_contains("Hello back")

    send(owner, {:jido_terminal, ref, {:key, :escape}})
    assert :ok = Task.await(task)
    assert_receive :terminal_closed
  end

  test "shows an application startup failure after the first frame" do
    test_pid = self()

    task =
      Task.async(fn ->
        Tui.run(
          application_startup: fn -> {:error, :application_boot_failed} end,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid]
        )
      end)

    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, first_frame}
    assert first_frame =~ "starting runtime"
    assert_frame_contains("startup failed · Esc exits")

    send(owner, {:jido_terminal, ref, {:key, :escape}})
    assert {:error, :application_boot_failed} = Task.await(task)
    assert_receive :terminal_closed
  end

  test "does not hide a process registration failure during cleanup" do
    test_pid = self()

    task =
      Task.async(fn ->
        Tui.run(
          runtime: FakeRuntime,
          process_register: fn :interactive, _owner, _opts ->
            exit(:missing_process_supervisor)
          end,
          process_stop: fn _name, _opts -> send(test_pid, :unexpected_process_stop) end,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          session_opts: [test_pid: test_pid]
        )
      end)

    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _first_frame}
    assert_frame_contains("startup failed · Esc exits")

    send(owner, {:jido_terminal, ref, {:key, :escape}})

    assert {:error, {:process_register_failed, {:exit, :missing_process_supervisor}}} =
             Task.await(task)

    refute_receive :unexpected_process_stop
    refute_receive :session_started
    assert_receive :terminal_closed
  end

  test "shows a startup failure and exits with its reason" do
    test_pid = self()

    task =
      Task.async(fn ->
        Tui.run(
          runtime: FakeRuntime,
          runtime_startup: fn ->
            send(test_pid, {:failing_runtime_owner, self()})
            {:error, :boot_failed}
          end,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          session_opts: [test_pid: test_pid]
        )
      end)

    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, first_frame}
    assert_receive {:failing_runtime_owner, runtime_owner}
    assert first_frame =~ "starting runtime"
    assert_frame_contains("startup failed · Esc exits")
    refute_receive :session_started, 50

    send(owner, {:jido_terminal, ref, {:key, :escape}})
    assert {:error, :boot_failed} = Task.await(task)
    refute Process.alive?(runtime_owner)
    assert_receive :terminal_closed
    refute_receive :terminal_closed, 50
  end

  test "keeps runtime resources open after a normal TUI detach" do
    test_pid = self()
    session_id = "close-runtime-#{System.unique_integer([:positive])}"

    task =
      Task.async(fn ->
        Tui.run(
          runtime: CloseRuntime,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          session_opts: [test_pid: test_pid],
          session_id: session_id
        )
      end)

    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _first_frame}
    assert_receive :close_session_started, 500
    assert_frame_contains("idle · Enter sends")

    send(owner, {:jido_terminal, ref, {:key, :escape}})
    assert :ok = Task.await(task)
    assert_receive :terminal_closed
    refute_receive :runtime_session_closed, 50
    {:ok, server} = Server.ensure_started(session_id)
    Server.stop(server)
    assert_receive :runtime_session_closed
  end

  test "EOF detaches while active session work continues" do
    {task, owner, ref, session_server, _session_id} = start_shutdown_tui()
    send_prompt(owner, ref)

    assert_receive {:shutdown_turn_started, start_pid, relay_pid, controller, "hello"}
    assert_receive {:shutdown_await_started, await_pid}
    send(owner, {:jido_terminal, ref, :eof})

    assert :ok = Task.await(task, 1_000)
    assert_receive :terminal_closed
    refute_receive {:shutdown_cancel_called, _cancel_pid}, 50
    refute_receive {:shutdown_session_closed, _pid}, 50
    assert start_pid == session_server
    refute relay_pid == session_server
    assert Process.alive?(relay_pid)
    assert Process.alive?(session_server)
    assert Process.alive?(controller)
    assert Process.alive?(await_pid)

    Server.stop(session_server)
    assert_receive {:shutdown_controller_closed, ^controller}
    assert_receive {:shutdown_session_closed, ^session_server}
    refute Process.alive?(relay_pid)
    refute Process.alive?(await_pid)
  end

  test "a draw failure detaches without cancelling session work" do
    {:ok, fail_control} = Agent.start_link(fn -> false end)

    {task, owner, ref, session_server, _session_id} =
      start_shutdown_tui(fail_control: fail_control)

    send_prompt(owner, ref)

    assert_receive {:shutdown_turn_started, _start_pid, _relay_pid, _controller, "hello"}
    assert_receive {:shutdown_await_started, await_pid}
    Agent.update(fail_control, fn _current -> true end)
    send(owner, {:jido_terminal, ref, {:resize, 41, 10}})

    assert {:error, :draw_failed} = Task.await(task, 1_000)
    assert_receive :terminal_closed
    refute_receive {:shutdown_cancel_called, _cancel_pid}, 50
    assert Process.alive?(session_server)
    assert Process.alive?(await_pid)
    Server.stop(session_server)
    assert_receive {:shutdown_session_closed, ^session_server}
    Agent.stop(fail_control)
  end

  test "a blocked startup owner is stopped within the shutdown bound" do
    test_pid = self()

    task =
      Task.async(fn ->
        Tui.run(
          runtime: FakeRuntime,
          runtime_startup: fn ->
            send(test_pid, {:blocked_runtime_owner, self()})
            receive do: (:never -> :ok)
          end,
          shutdown_timeout_ms: 50,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          session_opts: [test_pid: test_pid]
        )
      end)

    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _initial_frame}
    assert_receive {:blocked_runtime_owner, runtime_owner}
    send(owner, {:jido_terminal, ref, :eof})

    assert :ok = Task.await(task, 500)
    refute Process.alive?(runtime_owner)
    assert_receive :terminal_closed
    refute_receive :terminal_closed, 50
  end

  test "EOF stays bounded when runtime cancellation would block" do
    {task, owner, ref, session_server, _session_id} =
      start_shutdown_tui([],
        shutdown_timeout_ms: 80,
        shutdown_cancel_timeout_ms: 20,
        session_opts: [shutdown_mode: :block_cancel]
      )

    send_prompt(owner, ref)
    assert_receive {:shutdown_turn_started, _start_pid, relay, controller, "hello"}
    assert_receive {:shutdown_await_started, await_pid}
    send(owner, {:jido_terminal, ref, :eof})

    assert :ok = Task.await(task, 500)
    assert_receive :terminal_closed
    refute_receive {:shutdown_cancel_blocked, _cancel_pid}, 50
    refute relay == session_server
    assert Process.alive?(relay)
    assert Process.alive?(controller)
    assert Process.alive?(await_pid)
    Server.stop(session_server)
    assert_receive {:shutdown_session_closed, ^session_server}
    refute Process.alive?(relay)
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

    assert_receive :session_started, 10_000
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

  test "approves a pending review and keeps its decision in the transcript" do
    test_pid = self()

    task =
      Task.async(fn ->
        Tui.run(
          runtime: ApprovalRuntime,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          session_opts: [test_pid: test_pid],
          turn_opts: [test_pid: test_pid],
          review_opts: [test_pid: test_pid]
        )
      end)

    assert_receive :approval_session_started, 10_000
    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _initial_frame}
    send_prompt(owner, ref)
    assert_receive :approval_turn_started

    review_frame = assert_frame_contains("Review required")
    assert review_frame =~ "A approve · D deny"
    refute review_frame =~ "\e[31m"

    send(owner, {:jido_terminal, ref, {:text, "a"}})
    assert_receive {:approval_called, "review-1"}

    result_frame = assert_frame_contains("Approved change complete.")
    assert result_frame =~ "[approved] write_file"
    assert result_frame =~ "idle ·"

    stop_tui(task, owner, ref)
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

    assert_receive :session_started, 10_000
    assert_receive {:terminal_opened, owner, ref}
    assert_frame_contains("Loaded AGENTS.md")

    send(owner, {:jido_terminal, ref, {:text, "Review @value.ex"}})
    send(owner, {:jido_terminal, ref, {:key, :enter}})
    assert_receive :turn_started

    assert_receive {:turn_prompt, "Review value.ex",
                    %{"coding" => %{"files" => [%{"path" => "value.ex", "content" => content}]}}}

    assert content =~ "defmodule Value"
    assert_receive {:turn_awaited, _opts}
    assert_frame_contains("Hello back")
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

    refute_receive :session_started, 50
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
          terminal_adapter_opts: [test_pid: test_pid, fail_after: 2],
          session_opts: [test_pid: test_pid]
        )
      end)

    assert_receive :session_started, 10_000
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

  test "paints resolving before prompt preparation finishes" do
    test_pid = self()

    task =
      Task.async(fn ->
        Tui.run(
          runtime: FakeRuntime,
          prompt_preparer: fn _coding, prompt ->
            send(test_pid, {:prompt_preparation_blocked, self()})

            receive do
              :release_prompt_preparation ->
                {:ok, prompt, %{"coding" => %{"pack_id" => "jido.coding_pack"}}}
            end
          end,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          session_opts: [test_pid: test_pid],
          turn_opts: [test_pid: test_pid]
        )
      end)

    assert_receive :session_started, 10_000
    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _initial_frame}
    send_prompt(owner, ref)
    assert_receive {:prompt_preparation_blocked, worker}
    assert_frame_contains("resolving file mentions")
    refute_receive :turn_started, 50

    send(worker, :release_prompt_preparation)
    assert_receive :turn_started
    assert_frame_contains("Hello back")
    stop_tui(task, owner, ref)
  end

  test "runs turn start outside the terminal loop" do
    session_id = "blocking-start-#{System.unique_integer([:positive])}"
    {task, owner, ref} = start_failure_tui(:blocking_start, session_id: session_id)
    send_prompt(owner, ref)
    assert_receive {:failure_turn_started, :blocking_start}
    assert_receive {:start_turn_blocked, worker}
    assert_frame_contains("starting turn · Ctrl-C cancels")

    send(owner, {:jido_terminal, ref, {:key, :escape}})
    assert :ok = Task.await(task, 500)
    assert_receive :terminal_closed
    send(worker, :release_start_turn)
    {:ok, server} = Server.ensure_started(session_id)
    Server.stop(server)
  end

  test "awaits a turn without a terminal stream event" do
    {task, owner, ref} = start_failure_tui(:no_terminal)
    send_prompt(owner, ref)
    assert_receive {:failure_turn_started, :no_terminal}
    assert_frame_contains("completed without terminal event")
    stop_tui(task, owner, ref)
  end

  test "handles successful and failed cancellation" do
    {task, owner, ref} = start_failure_tui(:cancel_ok)
    send_prompt(owner, ref)
    assert_receive {:failure_turn_started, :cancel_ok}
    assert_frame_contains("running · Ctrl-C cancels")
    send(owner, {:jido_terminal, ref, {:key, :ctrl_c}})
    assert_receive {:cancel_called, :cancel_ok}
    assert_frame_contains("idle ·")
    stop_tui(task, owner, ref)

    {task, owner, ref} = start_failure_tui(:cancel_error)
    send_prompt(owner, ref)
    assert_receive {:failure_turn_started, :cancel_error}
    assert_frame_contains("running · Ctrl-C cancels")
    send(owner, {:jido_terminal, ref, {:key, :ctrl_c}})
    assert_receive {:cancel_called, :cancel_error}
    assert_frame_contains("error · :cancel_failed")
    stop_tui(task, owner, ref)
  end

  test "paints cancellation before the cancel call finishes" do
    {task, owner, ref} = start_failure_tui(:blocking_cancel)
    send_prompt(owner, ref)
    assert_receive {:failure_turn_started, :blocking_cancel}
    assert_frame_contains("running · Ctrl-C cancels")
    send(owner, {:jido_terminal, ref, {:key, :ctrl_c}})
    assert_receive {:cancel_blocked, worker}
    assert_frame_contains("cancelling")

    send(worker, :release_cancel)
    assert_frame_contains("idle ·")
    stop_tui(task, owner, ref)
  end

  test "keeps the completed answer when completion wins cancellation" do
    {task, owner, ref} = start_failure_tui(:already_finished)
    send_prompt(owner, ref)
    assert_receive {:failure_turn_started, :already_finished}
    assert_frame_contains("running · Ctrl-C cancels")

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

  defp start_failure_tui(mode, extra_opts \\ []) do
    test_pid = self()

    task =
      Task.async(fn ->
        Tui.run(
          runtime: FailureRuntime,
          terminal_adapter: FakeAdapter,
          terminal_adapter_opts: [test_pid: test_pid],
          session_opts: [test_pid: test_pid],
          turn_opts: [test_pid: test_pid, mode: mode],
          session_id:
            Keyword.get_lazy(extra_opts, :session_id, fn ->
              "failure-#{System.unique_integer([:positive])}"
            end)
        )
      end)

    assert_receive :failure_session_started, 10_000
    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _initial_frame}
    {task, owner, ref}
  end

  defp start_shutdown_tui(adapter_opts \\ [], tui_opts \\ []) do
    test_pid = self()
    session_id = "shutdown-#{System.unique_integer([:positive])}"
    session_opts = [test_pid: test_pid] |> Keyword.merge(Keyword.get(tui_opts, :session_opts, []))

    opts =
      [
        runtime: ShutdownRuntime,
        shutdown_timeout_ms: 400,
        terminal_adapter: FakeAdapter,
        terminal_adapter_opts: Keyword.put(adapter_opts, :test_pid, test_pid),
        session_opts: session_opts,
        turn_opts: [test_pid: test_pid],
        session_id: session_id
      ]
      |> Keyword.merge(tui_opts)
      |> Keyword.put(:session_opts, session_opts)

    task =
      Task.async(fn ->
        Tui.run(opts)
      end)

    assert_receive {:shutdown_session_opened, runtime_owner}, 10_000
    assert_receive {:terminal_opened, owner, ref}
    assert_receive {:frame, _initial_frame}
    {task, owner, ref, runtime_owner, session_id}
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

  defp flush_frames do
    receive do
      {:frame, _frame} -> flush_frames()
    after
      0 -> :ok
    end
  end

  defp assert_frame_contains(content, timeout \\ 500) do
    started_at = System.monotonic_time(:millisecond)
    receive_frame_with(content, started_at, timeout)
  end

  defp assert_frame_contains_all(contents, timeout) do
    started_at = System.monotonic_time(:millisecond)
    receive_frame_with_all(contents, started_at, timeout)
  end

  defp receive_frame_with_all(contents, started_at, timeout) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    remaining = max(timeout - elapsed, 0)

    receive do
      {:frame, frame} ->
        if Enum.all?(contents, &String.contains?(frame, &1)) do
          frame
        else
          receive_frame_with_all(contents, started_at, timeout)
        end
    after
      remaining -> flunk("no frame contained all of #{inspect(contents)}")
    end
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
