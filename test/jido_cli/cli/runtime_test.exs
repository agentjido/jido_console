defmodule Jido.Cli.Runtime.JidokaTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Runtime.Jidoka, as: Runtime
  alias Jidoka.Event
  alias Jidoka.Session.Data, as: Session

  test "completes a real asynchronous Jidoka session" do
    llm = fn _intent, _journal, _context ->
      {:ok, %{type: :final, content: "deterministic answer"}}
    end

    assert {:ok, %Session{} = session} = Runtime.start_session(Jido.Cli.DefaultAgent, [])
    assert {:ok, request} = Runtime.start_turn(session, "hello", self(), llm: llm)
    assert_receive {:jidoka_turn_event, %Event{event: :turn_finished}}, 1_000

    assert {:ok, %Session{}, "deterministic answer"} =
             Runtime.await(request, timeout: 30_000, cancel_on_timeout: false)
  end

  test "cancels an active public Jidoka request" do
    llm = fn _intent, _journal, _context ->
      Process.sleep(:infinity)
    end

    assert {:ok, %Session{} = session} = Runtime.start_session(Jido.Cli.DefaultAgent, [])
    assert {:ok, request} = Runtime.start_turn(session, "wait", self(), llm: llm)
    assert {:ok, %Jidoka.Cancellation{}} = Runtime.cancel(request, [])
  end
end
