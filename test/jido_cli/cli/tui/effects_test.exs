defmodule Jido.Cli.Tui.EffectsTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Tui.{Effects, State, Workers}
  alias Jidoka.Event

  defmodule ReviewRuntime do
    def approve(result, review, opts) do
      emit_review_event(opts)
      send(Keyword.fetch!(opts, :test_pid), {:review_response, :approve, self(), opts[:stream_to]})
      {:approved, result, review}
    end

    def deny(result, review, opts) do
      emit_review_event(opts)
      send(Keyword.fetch!(opts, :test_pid), {:review_response, :deny, self(), opts[:stream_to]})
      {:denied, result, review}
    end

    defp emit_review_event(opts) do
      event = Event.build(:turn_started, [], request_id: "review-request")
      send(Keyword.fetch!(opts, :stream_to), {:jidoka_turn_event, event})
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

      assert_receive {:review_response, ^decision, worker_pid, relay_pid}
      assert worker_pid != relay_pid
      assert_receive {:jidoka_turn_event, %Event{request_id: "review-request"}}
      assert_receive {:jido_tui_effect_result, ^worker_pid, outcome}
      assert {:ok, worker, remaining} = Workers.pop(workers, worker_pid)

      expected =
        case decision do
          :approve -> {:approved, :paused_result, :review}
          :deny -> {:denied, :paused_result, :review}
        end

      assert {:review_result, ^relay_pid, ^expected} = Effects.complete(worker, outcome)
      assert %{} = Workers.stop(remaining, relay_pid)
    end
  end
end
