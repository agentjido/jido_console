defmodule Jido.Console.Session.DrainTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Drain, Identity}

  test "drain completes only after owned workers and descendants are accounted for" do
    identity = Identity.new!(:worker, session_id: Identity.new!(:session).id)
    drain = identity |> then(&Drain.queue(Drain.new(), &1)) |> then(&Drain.activate(&1, identity, ["child"]))
    drain = Drain.start(drain, identity)
    assert {:error, :unknown_descendant} = Drain.collect(drain, identity, "missing")
    {:ok, drain} = Drain.collect(drain, identity, "child")
    {:ok, drain} = Drain.collect(drain, identity, identity.id)
    assert Drain.complete?(drain)
  end
end
