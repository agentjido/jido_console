defmodule Jido.Console.Tui.EffectsTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Request
  alias Jido.Console.Tui.{Effects, State, Workers}

  defmodule SessionServer do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:respond_review, "client", decision, request, review, opts}, from, test_pid) do
      send(test_pid, {:review_response, decision, request, review, opts, elem(from, 0)})
      {:reply, {:ok, :requested}, test_pid}
    end
  end

  test "runs approval and denial requests in monitored workers" do
    {:ok, server} = SessionServer.start_link(self())

    handle = %{server: server, client: %{id: "client"}}
    state = %{State.new(:session, {80, 24}) | session_client: handle}

    request = %Request{
      id: "session-request",
      request_id: "runtime-request",
      run_id: "run",
      session_id: "session"
    }

    for decision <- [:approve, :deny] do
      effect = {:respond_review, decision, request, :paused_result, :review}

      assert {:continue, workers} =
               Effects.dispatch(
                 state,
                 [effect],
                 :unused_runtime,
                 [review_opts: [test_pid: self()]],
                 %{}
               )

      assert_receive {:review_response, ^decision, ^request, :review, opts, worker_pid}, 500
      assert opts[:test_pid] == self()
      assert_receive {:jido_tui_effect_result, ^worker_pid, outcome}, 500
      assert {:ok, worker, remaining} = Workers.pop(workers, worker_pid)
      assert :ignore = Effects.complete(worker, outcome)
      assert remaining == %{}
    end
  end
end
