defmodule Jido.Console.ProcessTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Jido.Console.Process
  alias Jido.Console.Process.{Contract, Store}
  alias Jido.Console.Process.Supervisor, as: ProcessSupervisor

  setup do
    root = Path.join(System.tmp_dir!(), "jido-process-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    name = :"jido-process-#{System.unique_integer([:positive])}"
    opts = [jido_home: Path.join(root, "home"), name: name]
    {:ok, supervisor} = Jido.Console.Process.Supervisor.start_link(opts)

    on_exit(fn ->
      if Elixir.Process.alive?(supervisor) do
        try do
          GenServer.stop(supervisor, :shutdown, 1_000)
        catch
          :exit, _reason -> :ok
        end
      end

      File.rm_rf!(root)
    end)

    %{opts: opts, root: root}
  end

  test "catalog documents owner, readiness, and shutdown for each process" do
    catalog = Process.catalog()
    assert Process.statuses() == [:starting, :ready, :running, :stopping, :stopped, :failed]
    assert Map.has_key?(catalog, :interactive)
    assert Map.keys(catalog) == [:interactive]
    assert Process.spec(:interactive) == catalog.interactive
    assert Process.format_status([]) == "jido: no owned background processes\n"

    assert Process.format_stop(%{name: "interactive", status: :running}) ==
             "jido: interactive is running\n"

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
    refute Map.has_key?(record, :id)
    refute Map.has_key?(record, :owner_pid)
    refute Map.has_key?(record, :owner_os_pid)
    refute inspect(record) =~ :erlang.pid_to_list(pid) |> List.to_string()

    assert {:ok, [listed]} = Process.list(opts)
    assert listed.name == "interactive"
    assert listed.status == :ready
    assert listed.owner == "tui"
    refute Map.has_key?(listed, :id)
    refute Map.has_key?(listed, :owner_pid)
    refute Map.has_key?(listed, :owner_os_pid)
    refute inspect(listed) =~ :erlang.pid_to_list(pid) |> List.to_string()

    output = Process.format_status([listed])
    assert output =~ "interactive"
    refute output =~ :erlang.pid_to_list(pid) |> List.to_string()
    Elixir.Process.exit(pid, :kill)
  end

  test "shutdown is idempotent and clears the home marker", %{opts: opts} do
    pid = spawn(fn -> Elixir.Process.sleep(:infinity) end)
    ref = Elixir.Process.monitor(pid)
    assert {:ok, _} = Process.register(:interactive, pid, opts)
    assert {:ok, stopped} = Process.stop("interactive", opts)
    assert stopped.status == :stopped
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    assert {:ok, already} = Process.stop("interactive", opts)
    assert already.readiness == "already stopped"
    assert {:ok, []} = Process.list(opts)
  end

  test "an owner can stop its own record and finish cleanup", %{opts: opts} do
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, _record} = Process.register(:interactive, self(), opts)
        send(test_pid, {:owner_ready, self()})

        receive do
          :stop -> send(test_pid, {:owner_stopped, self(), Process.stop("interactive", opts)})
        end

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:owner_ready, ^owner}
    send(owner, :stop)

    assert_receive {:owner_stopped, ^owner, {:ok, %{status: :stopped}}}
    assert Elixir.Process.alive?(owner)
    assert {:ok, []} = Process.list(opts)

    ref = Elixir.Process.monitor(owner)
    send(owner, :finish)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
  end

  test "rejects a second live registration for the same process", %{opts: opts} do
    first = spawn(fn -> Elixir.Process.sleep(:infinity) end)
    second = spawn(fn -> Elixir.Process.sleep(:infinity) end)
    assert {:ok, _} = Process.register(:interactive, first, opts)
    assert {:error, :process_already_registered} = Process.register(:interactive, second, opts)
    Elixir.Process.exit(first, :kill)
    Elixir.Process.exit(second, :kill)
  end

  test "concurrent registrations use one process manager", %{opts: opts} do
    first = spawn(fn -> Elixir.Process.sleep(:infinity) end)
    second = spawn(fn -> Elixir.Process.sleep(:infinity) end)

    results =
      [first, second]
      |> Task.async_stream(&Process.register(:interactive, &1, opts), ordered: false)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %{status: :ready}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :process_already_registered}, &1)) == 1
    assert is_pid(Elixir.Process.whereis(opts[:name]))

    Elixir.Process.exit(first, :kill)
    Elixir.Process.exit(second, :kill)
  end

  test "rejects an id that conflicts with the contract identity", %{opts: opts} do
    owner = spawn(fn -> Elixir.Process.sleep(:infinity) end)

    assert {:error, {:process_identity_conflict, "interactive", "custom"}} =
             Process.register(:interactive, owner, Keyword.put(opts, :id, "custom"))

    assert {:ok, record} = Process.register(:interactive, owner, opts)
    assert record.name == "interactive"
    Elixir.Process.exit(owner, :kill)
  end

  test "accepts the exact contract id and ignores unrelated manager messages", %{opts: opts} do
    owner = spawn(fn -> Elixir.Process.sleep(:infinity) end)
    assert {:ok, %{name: "interactive"}} = Process.register(:interactive, owner, Keyword.put(opts, :id, "interactive"))

    manager = Elixir.Process.whereis(opts[:name])
    send(manager, {:EXIT, owner, :ignored})
    send(manager, {:DOWN, make_ref(), :process, self(), :ignored})
    send(manager, :unrelated)
    assert Elixir.Process.alive?(manager)

    assert {:error, _reason} = Process.stop("unknown", opts)
    Elixir.Process.exit(owner, :kill)
  end

  test "stops a stored ownerless marker through the manager", %{opts: opts} do
    {:ok, stored} =
      Contract.restore(%{
        kind: :interactive,
        name: "interactive",
        status: :running,
        readiness: "ready",
        failure: nil,
        owner_os_pid: nil
      })

    assert {:ok, _} = Store.put(stored, opts)
    assert {:ok, %{status: :stopped}} = ProcessSupervisor.stop_named("interactive", opts)
    assert {:ok, []} = Process.list(opts)
  end

  test "stored markers use only the stored projection", %{opts: opts} do
    owner = spawn(fn -> Elixir.Process.sleep(:infinity) end)
    assert {:ok, _record} = Process.register(:interactive, owner, opts)
    {:ok, dir} = Jido.Console.Home.path(:run, opts)

    assert {:ok, encoded} = File.read(Path.join(dir, "interactive.interactive.json"))
    assert {:ok, marker} = Jason.decode(encoded)

    assert Map.keys(marker) |> Enum.sort() ==
             ~w(failure kind name owner_os_pid readiness status)

    refute Map.has_key?(marker, "id")
    refute Map.has_key?(marker, "owner")
    refute Map.has_key?(marker, "owner_pid")
    Elixir.Process.exit(owner, :kill)
  end

  test "stored lookup validates kind and contract name as one identity", %{opts: opts} do
    identity = Contract.identity(:interactive)
    record = Contract.live(:interactive, self(), nil)
    assert {:ok, _record} = Store.put(record, opts)
    assert {:ok, stored} = Store.get(identity, opts)
    assert Contract.key(stored) == identity

    {:ok, dir} = Jido.Console.Home.path(:run, opts)
    path = Path.join(dir, "interactive.interactive.json")
    {:ok, marker} = path |> File.read!() |> Jason.decode()
    File.write!(path, Jason.encode!(Map.put(marker, "id", "custom")))

    assert {:error, {:process_marker_invalid, ^path, :invalid_process_marker}} =
             Store.get(identity, opts)

    File.write!(path, Jason.encode!(%{Map.delete(marker, "id") | "name" => "coding-runtime"}))

    assert {:error, {:process_marker_invalid, ^path, :invalid_process_marker}} =
             Store.get(identity, opts)
  end

  test "stop fails closed for a corrupt marker and stops a stale external owner", %{opts: opts} do
    assert {:ok, _home} = Jido.Console.Home.ensure(opts)
    assert {:ok, dir} = Jido.Console.Home.path(:run, opts)
    path = Path.join(dir, "interactive.interactive.json")
    File.write!(path, "{not-json")

    assert {:error, {:process_marker_invalid, ^path, _reason}} =
             Process.stop("interactive", opts)

    File.rm!(path)

    {:ok, external} =
      Contract.restore(%{
        kind: :interactive,
        name: "interactive",
        status: :running,
        readiness: "ready",
        failure: nil,
        owner_os_pid: 2_147_483_647
      })

    assert {:ok, _record} = Store.put(external, opts)
    assert {:ok, %{status: :stopped}} = Process.stop("interactive", opts)
    assert {:ok, []} = Process.list(opts)
  end

  test "skips invalid process markers instead of crashing status", %{opts: opts} do
    assert {:ok, _} = Jido.Console.Home.ensure(opts)
    {:ok, dir} = Jido.Console.Home.path(:run, opts)
    File.write!(Path.join(dir, "broken.json"), "{not-json")
    assert {:ok, []} = Process.list(opts)
  end

  test "normalizes missing, malformed, live, and undeletable stored markers", %{opts: opts} do
    identity = Contract.identity(:interactive)
    assert {:error, :process_not_found} = Store.get(identity, opts)
    assert :ok = Store.delete(identity, opts)

    assert {:ok, _home} = Jido.Console.Home.ensure(opts)
    {:ok, dir} = Jido.Console.Home.path(:run, opts)
    path = Path.join(dir, "interactive.interactive.json")

    File.write!(path, Jason.encode!(:invalid))
    assert {:error, {:process_marker_invalid, ^path, :invalid_process_marker}} = Store.get(identity, opts)

    invalid = %{
      "failure" => nil,
      "kind" => "unknown_process_kind",
      "name" => "interactive",
      "owner_os_pid" => nil,
      "readiness" => "ready",
      "status" => "running"
    }

    File.write!(path, Jason.encode!(invalid))
    assert {:error, {:process_marker_invalid, ^path, :invalid_process_marker}} = Store.get(identity, opts)

    File.rm!(path)
    File.mkdir!(path)

    assert {:error, {:process_marker_delete_failed, ^identity, _reason}} = Store.delete(identity, opts)
    File.rmdir!(path)

    {:ok, live} =
      Contract.restore(%{
        kind: :interactive,
        name: "interactive",
        status: :running,
        readiness: "ready",
        failure: nil,
        owner_os_pid: String.to_integer(System.pid())
      })

    assert {:ok, _record} = Store.put(live, opts)
    assert {:ok, []} = Store.reap(opts)

    stopped = %{live | status: :stopped}
    assert {:ok, _record} = Store.put(stopped, opts)
    assert {:ok, []} = Store.reap(opts)
  end

  test "the application owns one default process manager" do
    application = Elixir.Process.whereis(Jido.Console.Supervisor)
    manager = Elixir.Process.whereis(Jido.Console.Process.Supervisor)

    assert is_pid(application)
    assert is_pid(manager)

    assert {Jido.Console.Process.Supervisor, ^manager, :worker, [Jido.Console.Process.Supervisor]} =
             List.keyfind(
               Supervisor.which_children(application),
               Jido.Console.Process.Supervisor,
               0
             )
  end

  test "an explicit process manager restarts and stops with its supervisor", %{root: root} do
    name = :"jido-supervised-process-#{System.unique_integer([:positive])}"
    home = Path.join(root, "supervised-home")
    child = {Jido.Console.Process.Supervisor, name: name, jido_home: home}
    {:ok, supervisor} = Supervisor.start_link([child], strategy: :one_for_one)
    Elixir.Process.unlink(supervisor)
    first = Elixir.Process.whereis(name)
    first_ref = Elixir.Process.monitor(first)

    Elixir.Process.exit(first, :kill)
    assert_receive {:DOWN, ^first_ref, :process, ^first, :killed}

    second =
      supervisor
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {Jido.Console.Process.Supervisor, pid, :worker, _modules} when pid != first -> pid
        _child -> nil
      end)

    assert is_pid(second)
    assert Elixir.Process.alive?(second)

    second_ref = Elixir.Process.monitor(second)
    :ok = Supervisor.stop(supervisor, :shutdown)
    assert_receive {:DOWN, ^second_ref, :process, ^second, :shutdown}
    refute Elixir.Process.whereis(name)
  end

  test "register succeeds after the previous owner process exits", %{opts: opts} do
    parent = self()

    first =
      spawn(fn ->
        {:ok, _} = Process.register(:interactive, self(), opts)
        send(parent, :first_ready)
        receive do: (:go -> :ok)
      end)

    assert_receive :first_ready
    send(first, :go)
    assert_receive_gone(first)

    second = spawn(fn -> Elixir.Process.sleep(:infinity) end)
    assert {:ok, record} = Process.register(:interactive, second, opts)
    assert record.status == :ready
    Elixir.Process.exit(second, :kill)
  end

  test "owner exit and supervisor stop leave no owned process", %{opts: opts} do
    pid = spawn(fn -> Elixir.Process.sleep(:infinity) end)
    assert {:ok, _} = Process.register(:interactive, pid, opts)
    Elixir.Process.exit(pid, :kill)
    assert_receive_gone(pid)

    assert {:ok, records} = Process.stop_all(opts)
    assert Enum.all?(records, &(&1.status == :stopped))
    assert {:ok, []} = Process.list(opts)
  end

  test "stale active markers are reaped from an isolated home", %{opts: opts} do
    assert {:ok, _} = Jido.Console.Home.ensure(opts)

    {:ok, stale} =
      Contract.restore(%{
        kind: :interactive,
        name: "interactive",
        status: :running,
        readiness: "terminal and runtime are ready",
        failure: nil,
        owner_os_pid: nil
      })

    assert {:ok, _} = Store.put(stale, opts)
    assert {:ok, [reaped]} = Process.reap(opts)
    assert reaped.name == "interactive"
    assert {:ok, []} = Process.list(opts)
  end

  test "stop-all reports a stale stored marker as stopped", %{opts: opts} do
    {:ok, stale} =
      Contract.restore(%{
        kind: :interactive,
        name: "interactive",
        status: :running,
        readiness: "ready",
        failure: nil,
        owner_os_pid: nil
      })

    assert {:ok, _} = Store.put(stale, opts)

    assert {:ok, [%{name: "interactive", status: :stopped, readiness: "stopped"}]} =
             Process.stop_all(opts)
  end

  test "registration removes its monitor when the marker cannot be stored", %{opts: opts} do
    home = Keyword.fetch!(opts, :jido_home)
    File.write!(home, "not a directory")
    owner = spawn(fn -> Elixir.Process.sleep(:infinity) end)

    assert {:error, {:home_path_not_directory, ^home, :regular}} =
             Process.register(:interactive, owner, opts)

    assert Elixir.Process.alive?(owner)
    Elixir.Process.exit(owner, :kill)
  end

  test "rejects non-map contract restoration and non-atom marker fields", %{opts: opts} do
    assert {:error, :invalid_process_marker} = Contract.restore(:invalid)
    {:ok, dir} = Jido.Console.Home.path(:run, opts)
    File.mkdir_p!(dir)
    path = Path.join(dir, "interactive.interactive.json")

    File.write!(
      path,
      Jason.encode!(%{
        "failure" => nil,
        "kind" => 42,
        "name" => "interactive",
        "owner_os_pid" => nil,
        "readiness" => "ready",
        "status" => "running"
      })
    )

    assert {:error, {:process_marker_invalid, ^path, :invalid_process_marker}} =
             Store.get(Contract.identity(:interactive), opts)
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
