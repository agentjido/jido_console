defmodule Jido.Console.Session.ClientTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Client, Identity, Supervisor}

  test "the public interface contains only handle-owned client operations" do
    assert Client.__info__(:functions) ==
             [
               ack: 2,
               attach: 1,
               attach: 2,
               await: 2,
               await: 3,
               cancel: 3,
               cancel_and_wait: 3,
               cancel_and_wait: 4,
               capabilities: 0,
               configure_runtime: 3,
               configure_runtime: 4,
               detach: 1,
               detach_async: 1,
               recover: 1,
               respond_review: 4,
               respond_review: 5,
               runtime_info: 1,
               send_input: 2,
               snapshot: 1,
               start_operation: 2,
               start_turn: 2,
               start_turn: 3
             ]
  end

  test "a client can attach and detach with exact session identity" do
    suffix = System.unique_integer([:positive])
    opts = [name: :"client-#{suffix}", registry: :"client-reg-#{suffix}", sessions: :"client-dyn-#{suffix}"]
    {:ok, pid} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    session = Identity.new!(:session)

    assert {:ok, handle} = Client.attach(session.id, registry: opts[:registry], supervisor: opts[:sessions])
    refute Map.has_key?(handle, :delivery)
    assert {:ok, input} = Client.send_input(handle, "hello")
    assert input.status == :accepted
    assert input.identity.session_id == session.id
    assert :ok = Client.detach(handle)
    assert Process.alive?(handle.server)

    assert Enum.sort(Client.capabilities()) ==
             Enum.sort(~w(attach detach input output snapshot control capability ack recover))
  end
end
