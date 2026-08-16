defmodule Jido.Console.Session.Client.JSONTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Client.JSON

  test "JSON output is JSON-compatible and does not write automation JSONL" do
    assert {:ok, json} = JSON.encode_stream([%{"type" => "run_started", "sequence" => 1}])
    assert {:ok, [%{"type" => "run_started"}]} = Jason.decode(json)
    source = File.read!("lib/jido_console/session/client/json.ex")
    assert source =~ "Automation.JSONL"
    refute source =~ "JSONL.write"
  end
end
