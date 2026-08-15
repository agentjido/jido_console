defmodule Jido.Console.Session.Client.TUITest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Identity, Supervisor}
  alias Jido.Console.Session.Client.TUI

  test "the TUI can detach during work and reattach to the same session" do
    suffix = System.unique_integer([:positive])
    opts = [name: :"tui-#{suffix}", registry: :"tui-reg-#{suffix}", sessions: :"tui-dyn-#{suffix}"]
    {:ok, pid} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    session = Identity.new!(:session)
    attach_opts = [registry: opts[:registry], supervisor: opts[:sessions]]

    assert {:ok, handle} = TUI.attach(session.id, attach_opts)
    assert Process.alive?(handle.server)
    assert :ok = TUI.detach(handle)
    assert Process.alive?(handle.server)
    assert {:ok, again} = TUI.reattach(handle, attach_opts)
    assert again.session.id == session.id
  end
end
