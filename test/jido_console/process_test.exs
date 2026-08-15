defmodule Jido.Console.ProcessTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Jido.Console.Process
  alias Jido.Console.Process.Store

  setup do
    root = Path.join(System.tmp_dir!(), "jido-process-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    name = :"jido-process-#{System.unique_integer([:positive])}"
    opts = [jido_home: Path.join(root, "home"), name: name]
    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: opts, root: root}
  end

  test "catalog documents owner, readiness, and shutdown for each process" do
    catalog = Process.catalog()
    assert Map.has_key?(catalog, :interactive)
    assert Map.has_key?(catalog, :coding_runtime)

    Enum.each(catalog, fn {_kind, spec} ->
      assert spec.owner != ""
      assert spec.readiness != ""
      assert spec.shutdown != ""
      assert spec.name != ""
    end)
  end

  test "status reports owned processes without private identifiers", %{opts: opts} do
    pid = spawn(fn -> Elixir.Process.sleep(:infinity) end)
    assert {:ok, record} = Process.register(:interactive, pid, opts)
    refute Map.has_key?(record, :owner_pid)
    refute inspect(record) =~ :erlang.pid_to_list(pid) |> List.to_string()

    assert {:ok, [listed]} = Process.list(opts)
    assert listed.name == "interactive"
    assert listed.status == :ready
    assert listed.owner == "tui"
    refute inspect(listed) =~ :erlang.pid_to_list(pid) |> List.to_string()

    output = Process.format_status([listed])
    assert output =~ "interactive"
    refute output =~ :erlang.pid_to_list(pid) |> List.to_string()
    Elixir.Process.exit(pid, :kill)
  end

  test "shutdown is idempotent and clears the home marker", %{opts: opts} do
    pid = spawn(fn -> Elixir.Process.sleep(:infinity) end)
    assert {:ok, _} = Process.register(:interactive, pid, opts)
    assert {:ok, stopped} = Process.stop("interactive", opts)
    assert stopped.status == :stopped
    assert {:ok, already} = Process.stop("interactive", opts)
    assert already.readiness == "already stopped"
    assert {:ok, []} = Process.list(opts)
  end

  test "owner exit and supervisor stop leave no owned process", %{opts: opts} do
    pid = spawn(fn -> Elixir.Process.sleep(:infinity) end)
    assert {:ok, _} = Process.register(:coding_runtime, pid, opts)
    Elixir.Process.exit(pid, :kill)
    assert_receive_gone(pid)

    assert {:ok, records} = Process.stop_all(opts)
    assert Enum.all?(records, &(&1.status == :stopped))
    assert {:ok, []} = Process.list(opts)
  end

  test "stale active markers are reaped from an isolated home", %{opts: opts} do
    assert {:ok, _} = Jido.Console.Home.ensure(opts)

    stale = %{
      id: "interactive",
      kind: :interactive,
      name: "interactive",
      owner: "tui",
      status: :running,
      readiness: "terminal and runtime are ready",
      failure: nil,
      owner_pid: nil
    }

    assert {:ok, _} = Store.put(stale, opts)
    assert {:ok, [reaped]} = Process.reap(opts)
    assert reaped.id == "interactive"
    assert {:ok, []} = Process.list(opts)
  end

  test "jido status and stop use the process contract", %{opts: opts} do
    pid = spawn(fn -> Elixir.Process.sleep(:infinity) end)
    assert {:ok, _} = Process.register(:interactive, pid, opts)

    output = capture_io(fn -> assert :ok = Jido.Console.run(["status"], opts) end)
    assert output =~ "interactive"
    refute output =~ :erlang.pid_to_list(pid) |> List.to_string()

    stop_output = capture_io(fn -> assert :ok = Jido.Console.run(["stop"], opts) end)
    assert stop_output =~ "stopped interactive"

    empty = capture_io(fn -> assert :ok = Jido.Console.run(["stop"], opts) end)
    assert empty =~ "no owned background processes"
  end

  defp assert_receive_gone(pid) do
    ref = Elixir.Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 200
  end
end
