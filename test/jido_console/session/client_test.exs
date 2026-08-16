defmodule Jido.Console.Session.ClientTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Client, Identity, Supervisor}

  test "a client can attach and detach with exact session identity" do
    suffix = System.unique_integer([:positive])
    opts = [name: :"client-#{suffix}", registry: :"client-reg-#{suffix}", sessions: :"client-dyn-#{suffix}"]
    {:ok, pid} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    session = Identity.new!(:session)

    assert {:ok, handle} = Client.attach(session.id, registry: opts[:registry], supervisor: opts[:sessions])
    assert {:ok, input} = Client.send_input(handle, "hello")
    assert input.status == :accepted
    assert input.identity.session_id == session.id
    assert :ok = Client.detach(handle)
    assert Process.alive?(handle.server)

    assert Enum.sort(Client.capabilities()) ==
             Enum.sort(~w(attach detach input output snapshot control capability ack recover))
  end
end
