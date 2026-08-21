defmodule Jido.Console.Session.ThreadTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Queue, Thread, View}

  defmodule Resources do
    def status(_resources), do: %{"status" => "ready"}
  end

  test "partial events stay ordered and publish as one complete coalesced view" do
    run_ref = make_ref()
    state = state(run_ref)
    {attachment_ref, _view, state} = View.attach(state, self())

    state =
      Enum.reduce(1..3, state, fn sequence, state ->
        event =
          Jidoka.Event.build(:llm_delta, [],
            request_id: "request-1",
            seq: sequence,
            data: %{text: Integer.to_string(sequence)}
          )

        Thread.bridge_event(state, run_ref, "request-1", event)
      end)

    refute_receive {:jido_console_view, ^attachment_ref, _view}
    assert Enum.map(View.from_thread(state).partial, & &1.seq) == [1, 2, 3]
    assert is_reference(state.partial_publish_token)

    token = state.partial_publish_token
    state = Thread.publish_partial(state, run_ref, token)

    assert_receive {:jido_console_view, ^attachment_ref, %View{} = published}
    assert Enum.map(published.partial, & &1.seq) == [1, 2, 3]
    refute_receive {:jido_console_view, ^attachment_ref, _view}

    next_run = make_ref()
    next_state = %{state | bridge: %{run_ref: next_run}}
    assert Thread.publish_partial(next_state, run_ref, token) == next_state
  end

  defp state(run_ref) do
    spec = Jidoka.Agent.Spec.new!(id: "thread-agent", instructions: "Test.", model: %{provider: :test, id: "model"})
    {:ok, session} = Jidoka.Session.Data.start(spec, session_id: "thread-1")

    %{
      thread_id: "thread-1",
      status: :running,
      revision: 0,
      session: session,
      history: [],
      history_truncated?: false,
      partial: [],
      partial_publish_ref: nil,
      partial_publish_token: nil,
      partial_publish_run_ref: nil,
      active: %{id: "item-1", request_id: "request-1", text: "hello"},
      bridge: %{run_ref: run_ref},
      review: nil,
      queue: Queue.new(),
      resources_module: Resources,
      resources: %{},
      error: nil,
      subscribers: %{},
      monitors: %{},
      options: [partial_publish_interval_ms: 1_000]
    }
  end
end
