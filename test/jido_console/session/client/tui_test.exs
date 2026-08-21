defmodule Jido.Console.Session.Client.TUITest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Client, View}
  alias Jido.Console.Session.Client.TUI
  alias Jido.Console.Tui.State

  test "applies the same complete View used by a non-TUI caller" do
    handle = %Client{thread_id: "tui-thread", owner_options: [], attachment_ref: make_ref()}
    state = State.new(nil, {80, 24}, session_client: handle)

    view =
      View.new!(
        thread_id: "tui-thread",
        status: :running,
        revision: 4,
        session_revision: 2,
        transcript: [%{role: :user, content: "old"}, %{role: :assistant, content: "answer"}],
        history: [],
        partial: [%{event: "llm_delta", data: %{"text" => "live"}}],
        active: %{"queue_item_id" => "command", "request_id" => "request", "input" => "new"},
        queue: [],
        resources: %{"status" => "ready"}
      )

    assert {:ok, state} = TUI.apply_view(handle, state, view)
    assert State.active_request(state).request_id == "request"
    assert State.active_turn(state).assistant == "live"
  end

  test "rejects a cross-thread View" do
    handle = %Client{thread_id: "one", owner_options: [], attachment_ref: make_ref()}
    state = State.new(nil, {80, 24})
    view = View.new!(thread_id: "two", status: :idle, revision: 0)
    assert {:error, :cross_thread_view, ^state} = TUI.apply_view(handle, state, view)
  end
end
