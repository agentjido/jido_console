defmodule Jido.Console.Tui.EffectsTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.{Effects, State}
  alias Jido.Console.Tui.Workers.Worker

  defmodule Client do
    def submit(handle, prompt, opts) do
      send(handle, {:submitted, prompt, opts})
      {:ok, %{queue_item_id: opts[:command_id], request_id: opts[:request_id]}}
    end

    def cancel(handle, request_id) do
      send(handle, {:cancelled, request_id})
      {:ok, :requested}
    end

    def approve(handle, request_id, review_id) do
      send(handle, {:reviewed, :approve, request_id, review_id})
      {:ok, :requested}
    end

    def deny(handle, request_id, review_id) do
      send(handle, {:reviewed, :deny, request_id, review_id})
      {:ok, :requested}
    end

    def select_model(handle, identity) do
      send(handle, {:selected_model, identity})
      {:ok, %{"identity" => identity, "tier" => "beta", "locked" => false}}
    end

    def select_agent(handle, source) do
      send(handle, {:selected_agent, source})
      {:ok, %{"binding_state" => "ready_unlocked"}}
    end

    def select_execution_policy(handle, id, opts) do
      send(handle, {:selected_execution_policy, id, opts})
      {:ok, %{"binding_state" => "ready_unlocked"}}
    end

    def detach(handle) do
      send(handle, :detached_for_new_session)
      :ok
    end

    def attach(thread_id, opts) do
      send(Keyword.fetch!(opts, :subscriber), {:attached_new_session, thread_id, opts})
      {:ok, %{handle: :new_handle, view: :new_view}}
    end
  end

  test "dispatches model selection through the session client" do
    state = State.new(nil, {80, 24}, session_client: self())
    opts = [session_client_module: Client]

    assert {:continue, workers} =
             Effects.dispatch(state, [{:select_model, "ollama:llama3.2"}], :unused, opts, %{})

    assert_receive {:selected_model, "ollama:llama3.2"}

    assert {:event, {:model_selected, %{"identity" => "ollama:llama3.2", "tier" => "beta", "locked" => false}}} =
             complete_one(workers)
  end

  test "dispatches agent and execution-policy selection through the TUI client" do
    state = State.new(nil, {80, 24}, session_client: self())
    opts = [session_client_module: Client]

    assert {:continue, workers} =
             Effects.dispatch(
               state,
               [
                 {:select_agent, "agents/review agent.yaml"},
                 {:select_execution_policy, "coding.trusted-workspace", "/work/project"}
               ],
               :unused,
               opts,
               %{}
             )

    assert_receive {:selected_agent, "agents/review agent.yaml"}
    assert_receive {:selected_execution_policy, "coding.trusted-workspace", [project_root: "/work/project"]}

    completions = Enum.map(workers, fn {_pid, worker} -> complete_worker(worker) end)
    assert Enum.any?(completions, &match?({:event, {:binding_selected, :agent, _result}}, &1))
    assert Enum.any?(completions, &match?({:event, {:binding_selected, :execution_policy, _result}}, &1))
  end

  test "creates a clean thread without copying direct policy consent" do
    state = State.new(nil, {80, 24}, session_client: self())

    opts = [
      session_client_module: Client,
      session_subscriber: self(),
      id_generator: &"new-#{&1}",
      execution_policy: "coding.trusted-workspace",
      execution_policy_direct_choice: :private,
      coding_profile: "coding.local",
      session_id: "old-thread"
    ]

    assert {:continue, workers} = Effects.dispatch(state, [:new_session], :unused, opts, %{})
    assert_receive :detached_for_new_session
    assert_receive {:attached_new_session, "new-thread", attach_opts}
    refute Keyword.has_key?(attach_opts, :execution_policy)
    refute Keyword.has_key?(attach_opts, :execution_policy_direct_choice)
    refute Keyword.has_key?(attach_opts, :coding_profile)
    refute Keyword.has_key?(attach_opts, :session_id)

    assert {:event, {:session_replaced, %{handle: :new_handle, view: :new_view}}} = complete_one(workers)
  end

  test "dispatches current submit and control commands" do
    state = State.new(nil, {80, 24}, session_client: self())
    opts = [session_client_module: Client, id_generator: &"fixed-#{&1}"]

    assert {:continue, workers} =
             Effects.dispatch(state, [{:start_turn, "hello"}], :unused, opts, %{})

    assert_receive {:submitted, "hello", submit_opts}
    assert submit_opts[:command_id] == "fixed-tui-command"
    assert submit_opts[:request_id] == "fixed-tui-request"
    assert {:event, {:turn_started, %{request_id: "fixed-tui-request"}}} = complete_one(workers)

    request = %{request_id: "request-1"}
    assert {:continue, workers} = Effects.dispatch(state, [{:cancel_turn, request}], :unused, opts, %{})
    assert_receive {:cancelled, "request-1"}
    assert :ignore = complete_one(workers)
  end

  test "treats a review-pending cancellation as a control no-op" do
    worker = %Worker{pid: self(), ref: make_ref(), kind: :session_cancel}

    assert :ignore = Effects.complete(worker, {:ok, {:error, :review_pending}})
  end

  defp complete_one(workers) do
    assert [{pid, worker}] = Map.to_list(workers)
    assert_receive {:jido_tui_effect_result, ^pid, outcome}
    Effects.complete(worker, outcome)
  end

  defp complete_worker(worker) do
    assert_receive {:jido_tui_effect_result, pid, outcome} when pid == worker.pid
    Effects.complete(worker, outcome)
  end
end
