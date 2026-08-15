defmodule Jido.Console.Session.WorkerTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Identity, Worker}

  test "model and tool work runs outside the session owner process" do
    identity = Identity.new!(:request, session_id: Identity.new!(:session).id)
    parent = self()

    assert {:ok, result} =
             Worker.run(identity: identity, fun: fn -> send(parent, {:ran_on, self()}); :done end)

    assert_receive {:ran_on, worker}
    refute worker == parent
    assert result.identity.id == identity.id
    assert result.session_id == identity.session_id
  end
end
