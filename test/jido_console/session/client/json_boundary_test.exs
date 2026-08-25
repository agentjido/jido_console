defmodule Jido.Console.Session.Client.JSONBoundaryTest do
  use ExUnit.Case, async: true

  test "the JSON adapter uses Session.Client and no private runtime boundary" do
    root = Path.expand("../../../..", __DIR__)

    source =
      [
        "lib/jido_console/session/client/json.ex",
        "lib/jido_console/session/client/json/attachment.ex",
        "lib/jido_console/session/client/json/protocol.ex"
      ]
      |> Enum.map_join("\n", fn path -> File.read!(Path.join(root, path)) end)

    assert source =~ "Session.Client"
    refute source =~ "Session.Server"
    refute source =~ "Session.Registry"
    refute source =~ "Jido.Console.Storage"
    refute source =~ "Jidoka.Event"
    refute source =~ "Jidoka.Session"
  end
end
