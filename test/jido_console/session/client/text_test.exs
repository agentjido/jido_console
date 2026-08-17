defmodule Jido.Console.Session.Client.TextTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Client
  alias Jido.Console.Session.Client.Text
  alias Jido.Console.Session.Supervisor

  test "ordered outcomes, gaps, and errors have deterministic text" do
    text =
      Text.transcript([
        %{"type" => "run_started"},
        %{"type" => "delivery_gap", "last_acknowledged" => 3},
        %{"type" => "run_failed", "reason" => "boom"}
      ])

    assert text == "run_started\ngap after 3\nerror: boom"
    refute text =~ "#PID"
  end

  test "uses nested and fallback failure reasons" do
    assert Text.render(%{"type" => "delivery_gap"}) == "gap after 0"
    assert Text.render(%{"type" => "run_failed", "payload" => %{"reason" => "nested"}}) == "error: nested"
    assert Text.render(%{"type" => "run_failed"}) == "error: failed"
    assert Text.render(:invalid) == "unknown"
  end

  test "observes the typed semantic snapshot through the client contract" do
    suffix = System.unique_integer([:positive])
    opts = [name: :"text-#{suffix}", registry: :"text-reg-#{suffix}", sessions: :"text-dyn-#{suffix}"]
    {:ok, pid} = Supervisor.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

    attach_opts = [registry: opts[:registry], supervisor: opts[:sessions]]
    assert {:ok, %{handle: handle, snapshot: snapshot}} = Client.attach("text-session-#{suffix}", attach_opts)

    expected =
      snapshot
      |> get_in(["payload", "snapshot", "transcript"])
      |> List.wrap()
      |> Enum.map(& &1["type"])

    assert Text.observe(handle) == expected
    assert :ok = Client.detach(handle)
  end
end
