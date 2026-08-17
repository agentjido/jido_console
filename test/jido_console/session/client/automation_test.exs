defmodule Jido.Console.Session.Client.AutomationTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Client.Handle
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

    first_identity = Handle.identity(first)
    second_identity = Handle.identity(second)

    refute first_identity.attachment_id == second_identity.attachment_id
    refute first_identity.session_id == second_identity.session_id
  end
end
