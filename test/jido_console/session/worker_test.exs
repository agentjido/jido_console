defmodule Jido.Console.Session.WorkerTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Identity, Worker}

  test "model and tool work runs outside the session owner process" do
    identity = Identity.new!(:request, session_id: Identity.new!(:session).id)
    parent = self()

    assert {:ok, result} =
             Worker.run(
               identity: identity,
               fun: fn ->
                 send(parent, {:ran_on, self()})
                 :done
               end
             )

    assert_receive {:ran_on, worker}
    refute worker == parent
    assert result.identity.id == identity.id
    assert result.session_id == identity.session_id
  end

  test "a timed-out worker cannot become the next run's result" do
    identity = Identity.new!(:request, session_id: Identity.new!(:session).id)

    assert {:error, :worker_timeout} =
             Worker.run(
               identity: identity,
               timeout: 20,
               fun: fn ->
                 receive do
                   :never -> :late
                 after
                   5_000 -> :late
                 end
               end
             )

    assert {:ok, result} = Worker.run(identity: identity, timeout: 200, fun: fn -> :on_time end)
    assert result.result == :on_time
  end
end
