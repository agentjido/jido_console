defmodule Jido.Console.Session.Client.AutomationTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Client.Automation
  alias Jido.Console.Session.Supervisor

  test "each matrix cell attaches one fresh session" do
    suffix = System.unique_integer([:positive])
    opts = [name: :"auto-#{suffix}", registry: :"auto-reg-#{suffix}", sessions: :"auto-dyn-#{suffix}"]
    {:ok, pid} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    attach_opts = [registry: opts[:registry], supervisor: opts[:sessions]]

    assert {:ok, first} = Automation.attach_cell("cell-a-#{suffix}", attach_opts)
    assert {:ok, second} = Automation.attach_cell("cell-b-#{suffix}", attach_opts)
    refute first.server == second.server
    refute first.session.id == second.session.id
  end
end
