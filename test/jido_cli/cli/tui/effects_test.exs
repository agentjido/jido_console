defmodule Jido.Cli.Tui.EffectsTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Tui.{Effects, State, Workers}

  defmodule ReviewRuntime do
    def approve(result, review, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:review_response, :approve, self()})
      {:approved, result, review}
    end

    def deny(result, review, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:review_response, :deny, self()})
      {:denied, result, review}
    end
  end

  test "runs approval and denial responses in monitored workers" do
    state = State.new(:session, {80, 24})

    for decision <- [:approve, :deny] do
      effect = {:respond_review, decision, :paused_result, :review}

      assert {:continue, workers} =
               Effects.dispatch(
                 state,
                 [effect],
                 ReviewRuntime,
                 [review_opts: [test_pid: self()]],
                 %{}
               )

      assert_receive {:review_response, ^decision, worker_pid}
      assert_receive {:jido_tui_effect_result, ^worker_pid, outcome}
      assert {:ok, worker, %{}} = Workers.pop(workers, worker_pid)

      expected =
        case decision do
          :approve -> {:approved, :paused_result, :review}
          :deny -> {:denied, :paused_result, :review}
        end

      assert {:event, {:turn_result, ^expected}} = Effects.complete(worker, outcome)
    end
  end
end
