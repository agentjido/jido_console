defmodule Jido.Console.Session.Client.TUITest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Client, Identity, Server, Supervisor}
  alias Jido.Console.Session.Client.TUI
  alias Jido.Console.Tui.State
  alias Jidoka.Event

  defmodule Runtime do
    @behaviour Jido.Console.Runtime

    @impl true
    def start_session(_agent, opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def start_turn(session, _prompt, owner, _opts) do
      request = %{request_id: "detach-request", owner: owner, test_pid: session.test_pid}

      send(
        owner,
        {:jidoka_turn_event,
         Event.build(:llm_delta, [],
           request_id: request.request_id,
           seq: 0,
           data: %{chunk_type: :content, delta: "still running"}
         )}
      )

      {:ok, request}
    end

    @impl true
    def await(request, _opts) do
      send(request.test_pid, {:runtime_waiting, self()})

      receive do
        :finish ->
          send(
            request.owner,
            {:jidoka_turn_event, Event.build(:turn_finished, [], request_id: request.request_id, seq: 1)}
          )

          {:ok, %{test_pid: request.test_pid}, "still running"}
      end
    end

    @impl true
    def cancel(_request, _opts), do: {:error, :not_supported}
  end

  test "the TUI can detach during work and reattach to the same session" do
    suffix = System.unique_integer([:positive])
    opts = [name: :"tui-#{suffix}", registry: :"tui-reg-#{suffix}", sessions: :"tui-dyn-#{suffix}"]
    {:ok, pid} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    session = Identity.new!(:session)
    attach_opts = [registry: opts[:registry], supervisor: opts[:sessions]]

    assert {:ok, handle} = TUI.attach(session.id, attach_opts)
    assert Process.alive?(handle.server)
    assert :ok = TUI.detach(handle)
    assert Process.alive?(handle.server)
    assert {:ok, again} = TUI.reattach(handle, attach_opts)
    assert again.session.id == session.id
  end

  test "active runtime work and its transcript survive a TUI detach" do
    suffix = System.unique_integer([:positive])
    opts = [name: :"live-tui-#{suffix}", registry: :"live-tui-reg-#{suffix}", sessions: :"live-tui-dyn-#{suffix}"]
    {:ok, supervisor} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)

    session = Identity.new!(:session)
    attach_opts = [registry: opts[:registry], supervisor: opts[:sessions]]

    assert {:ok, first} = TUI.attach(session.id, attach_opts)
    on_exit(fn -> Server.stop(first.server) end)
    assert :ok = Client.configure_runtime(first, Runtime, :agent, test_pid: self())
    assert {:ok, request} = Client.start_turn(first, "keep working")
    assert_receive {:runtime_waiting, worker}

    assert :ok = TUI.detach(first)
    assert Process.alive?(first.server)

    assert {:ok, second} = TUI.attach(session.id, attach_opts)
    assert {:ok, %{configured?: true, active_request: ^request}} = Client.runtime_info(second)
    assert TUI.observe(second) == ["run_started", "model_delta"]

    restored =
      State.new(nil, {80, 24},
        session_snapshot: second.snapshot,
        session_request: request
      )

    assert restored.request == request
    assert restored.status == :running
    assert restored.streaming == "still running"

    send(worker, :finish)
    assert {:ok, _session, "still running"} = Client.await(second, request)
    assert TUI.observe(second) == ["run_started", "model_delta", "run_completed"]

    snapshot = Client.snapshot(second)
    assert snapshot["payload"]["state"]["outcomes"] |> List.last() |> get_in(["payload", "content"]) == "still running"
  end
end
