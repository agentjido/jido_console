defmodule Jido.Console.Session.ViewTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Queue, View}

  defmodule Resources do
    def status(_resources), do: %{"status" => "ready"}
  end

  test "validates views and manages exact subscriber identities" do
    assert %Zoi.Types.Struct{} = View.schema()
    assert {:error, :invalid_session_view} = View.new(%{})
    assert_raise ArgumentError, fn -> View.new!(%{}) end

    state = state()
    {attachment_ref, first, state} = View.attach(state, self())
    assert first.revision == 0

    state = View.publish(state)
    assert_receive {:jido_console_view, ^attachment_ref, %View{revision: 1}}
    assert View.detach(state, make_ref()) == state
    assert View.subscriber_down(state, make_ref()) == state
    assert View.detach(state, attachment_ref).subscribers == %{}
  end

  test "projects active, review, queue, and resource state without live values" do
    item = %{id: "item", request_id: "request", text: "hello"}
    {:ok, queue} = Queue.new() |> Queue.push(%{item | id: "queued"})

    view =
      View.from_thread(%{
        state()
        | active: item,
          review: %{data: %{"id" => "review"}},
          queue: queue,
          history_truncated?: true
      })

    assert view.active == %{"queue_item_id" => "item", "request_id" => "request", "input" => "hello"}
    assert view.review == %{"id" => "review"}
    assert hd(view.queue)["queue_item_id"] == "queued"
    assert view.resources == %{"status" => "ready"}
  end

  defp state do
    spec = Jidoka.Agent.Spec.new!(id: "view-agent", instructions: "Test.", model: %{provider: :test, id: "model"})
    {:ok, session} = Jidoka.Session.Data.start(spec, session_id: "view-thread")

    %{
      thread_id: "view-thread",
      status: :idle,
      revision: 0,
      session: session,
      history: [],
      history_truncated?: false,
      partial: [],
      active: nil,
      review: nil,
      queue: Queue.new(),
      resources_module: Resources,
      resources: %{},
      error: nil,
      subscribers: %{},
      monitors: %{}
    }
  end
end
