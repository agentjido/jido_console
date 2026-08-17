defmodule Jido.Console.Session.Client.JSONTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Client
  alias Jido.Console.Session.Client.JSON
  alias Jido.Console.Session.Supervisor

  test "JSON output is JSON-compatible and does not write automation JSONL" do
    assert {:ok, json} = JSON.encode_stream([%{"type" => "run_started", "sequence" => 1}])
    assert {:ok, [%{"type" => "run_started"}]} = Jason.decode(json)
    source = File.read!("lib/jido_console/session/client/json.ex")
    assert source =~ "Automation.JSONL"
    refute source =~ "JSONL.write"
  end

  test "sanitizes live runtime values and atoms recursively" do
    assert {:ok, json} =
             JSON.encode(%{
               type: :event,
               nested: [%{pid: self(), function: fn -> :ok end, reference: make_ref()}]
             })

    assert %{"type" => "event", "nested" => [%{"pid" => nil, "function" => nil, "reference" => nil}]} =
             Jason.decode!(json)
  end

  test "observes the typed semantic snapshot through JSON encoding" do
    suffix = System.unique_integer([:positive])
    opts = [name: :"json-#{suffix}", registry: :"json-reg-#{suffix}", sessions: :"json-dyn-#{suffix}"]
    {:ok, pid} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

    attach_opts = [registry: opts[:registry], supervisor: opts[:sessions]]
    assert {:ok, %{handle: handle, snapshot: snapshot}} = Client.attach("json-session-#{suffix}", attach_opts)

    expected =
      snapshot
      |> get_in(["payload", "snapshot", "transcript"])
      |> List.wrap()
      |> Enum.map(& &1["type"])

    assert JSON.observe(handle) == expected
    assert :ok = Client.detach(handle)
  end
end
