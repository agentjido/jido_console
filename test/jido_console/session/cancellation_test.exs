defmodule Jido.Console.Session.CancellationTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Cancellation, Drain, Identity}

  test "graceful cancellation reports requested and saving before cancelled" do
    identity = Identity.new!(:request, session_id: Identity.new!(:session).id)
    cancellation = identity |> Cancellation.request(Drain.activate(Drain.new(), identity, [])) |> Cancellation.saving()
    assert cancellation.status == :saving
    {:ok, drain} = Drain.collect(cancellation.drain, identity, identity.id)
    {:ok, cancelled} = Cancellation.complete(%{cancellation | drain: drain})
    assert cancelled.status == :cancelled
    assert Cancellation.request_again(cancelled, identity).status == :cancelled

    incomplete = Cancellation.request(identity, Drain.new())
    assert {:error, :drain_incomplete} = Cancellation.complete(incomplete)
    assert Cancellation.force_kill(incomplete).status == :force_killed
    assert Cancellation.force_kill(cancelled) == cancelled

    foreign = Identity.new!(:request, session_id: Identity.new!(:session).id)
    assert {:error, :cross_session_result} = Cancellation.request_again(cancelled, foreign)
  end
end
