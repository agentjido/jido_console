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
end
