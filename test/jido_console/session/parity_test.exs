defmodule Jido.Console.Session.ParityTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{Client, Parity, Server}
  alias Jido.Console.Session.Client.{Automation, TUI}
  alias Jido.Console.Runtime.Result
  alias Jidoka.Event

  defmodule Runtime do
    @behaviour Jido.Console.Runtime

    @impl true
    def start_session(_agent, _opts), do: {:ok, :parity_session}

    @impl true
    def start_turn(:parity_session, _prompt, owner, _opts) do
      request = %{request_id: "parity-request"}

      delta =
        Event.build(:llm_delta, [],
          request_id: request.request_id,
          seq: 0,
          data: %{chunk_type: :content, delta: "same"}
        )

      send(owner, {:jidoka_turn_event, delta})

      send(
        owner,
        {:jidoka_turn_event, Event.build(:turn_finished, [delta], request_id: request.request_id, seq: 1)}
      )

      {:ok, request}
    end

    @impl true
    def await(request, _opts),
      do: Result.ok(request.request_id, :parity_session, request, "same")

    @impl true
    def cancel(_request, _opts), do: {:error, :not_supported}
  end

  test "live clients observe the same ordered outcomes" do
    session_id = "parity-#{System.unique_integer([:positive])}"

    assert {:ok, tui} = TUI.attach(session_id)
    assert {:ok, automation} = Automation.attach_cell(session_id)
    assert {:ok, text} = Client.attach(session_id)
    assert {:ok, json} = Client.attach(session_id)

    handles = %{tui: tui, automation: automation, text: text, json: json}

    on_exit(fn ->
      Enum.each(handles, fn {_kind, handle} -> Client.detach(handle) end)
      Server.stop(tui.server)
    end)

    assert :ok = Client.configure_runtime(tui, Runtime, :agent)
    assert {:ok, request} = Client.start_turn(tui, "show parity")
    assert %Result{outcome: %Result.Ok{content: "same"}} = Client.await(tui, request)

    assert Parity.same_outcomes?(handles)
    observed = Parity.observe(handles)
    assert observed.tui == ["run_started", "model_delta", "run_completed"]
    assert observed.automation == observed.tui
    assert observed.text == observed.tui
    assert observed.json == observed.tui
  end
end
