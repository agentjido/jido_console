defmodule Jido.Console.Session.ClientTest do
  use Jido.Console.SessionClientContract, driver: Jido.Console.Session.Client.Local

  alias Jido.Console.Session.{Catalog, Client}
  alias Jido.Console.Session.Client.{Boundary, Driver, Local}

  test "the local driver implements the renderer-neutral behavior" do
    callbacks = Driver.behaviour_info(:callbacks)
    assert Enum.all?(callbacks, fn {name, arity} -> function_exported?(Local, name, arity) end)
  end

  test "command effects use the same canonical output path", context do
    command = %{
      "id" => "cmd_help",
      "version" => "1",
      "name" => "help",
      "help" => "Show help.",
      "input_schema" => %{},
      "output_schema" => %{},
      "permissions" => [],
      "provenance" => %{"owner" => "jido_console"}
    }

    {:ok, catalog} = Catalog.put_command(Local.default_catalog(), command)
    opts = Keyword.put(context.client_opts, :catalog, catalog)
    assert {:ok, attached} = Client.attach(context.session.id, opts)
    assert {:ok, effect} = Client.invoke(attached.handle, "help", data: %{"page" => 1})
    assert effect.command_id == "cmd_help"

    assert_receive {:jido_console_session, attachment_id, :output_ready}
    assert attachment_id == attached.handle.attachment.id
    assert {:ok, batch} = Client.output(attached.handle)
    assert Enum.map(batch["payload"]["events"], & &1["type"]) == ["command_effected"]
  end

  test "the adapter bypass allowlist is fixed to one TUI migration path" do
    assert Boundary.legacy_allowlist() == ["lib/jido_console/cli/tui.ex"]

    adapters = [
      "lib/jido_console/session/client/automation.ex",
      "lib/jido_console/session/client/json.ex",
      "lib/jido_console/session/client/text.ex",
      "lib/jido_console/session/client/tui.ex"
    ]

    assert :ok = Boundary.check(adapters)
  end

  test "the public contract records its process-lifetime boundary" do
    assert Client.limitation() =~ "process-lifetime only"
    assert Client.limitation() =~ "application restart"
  end
end
