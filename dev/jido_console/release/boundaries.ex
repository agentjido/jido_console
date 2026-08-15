defmodule Jido.Console.Release.Boundaries do
  @moduledoc "Runs controlled file and runtime boundary probes for release preparation."

  alias Jidoka.CodingPack.{Error, Read, Workspace}
  alias Jido.Console.Coding.Local.Adapter
  alias Jidoka.Cancellation.Token

  @canary "jido-controlled-boundary-canary\n"

  @doc false
  @spec file_boundary!(keyword()) :: map()
  def file_boundary!(opts \\ []) do
    probe = Keyword.get(opts, :probe, &Read.run/2)
    runs = Enum.map(1..2, fn _index -> file_run!(probe) end)

    unless Enum.at(runs, 0) == Enum.at(runs, 1) do
      raise "file-boundary probes are not repeatable"
    end

    %{
      "status" => "passed",
      "canary_sha256" => digest(@canary),
      "cases" => hd(runs),
      "repeat_runs" => 2,
      "risk_control" => "jido_console-m1e15"
    }
  end

  @doc false
  @spec runtime_boundary!(keyword()) :: map()
  def runtime_boundary!(opts \\ []) do
    network = Keyword.get(opts, :network_probe, &network_probe!/0).()
    processes = Keyword.get(opts, :process_probe, &process_probe!/0).()

    expected_network = %{"external" => "denied", "loopback" => "denied"}
    expected_processes = Map.new(~w(success rejection cancellation timeout owner_exit), &{&1, "denied"})

    validate_classes!("network", network, expected_network)
    validate_classes!("process", processes, expected_processes)

    %{
      "status" => "passed",
      "network" => network,
      "processes" => processes,
      "public_endpoints_contacted" => 0,
      "risk_controls" => ["jido_console-m1e16", "jido_console-m1e17"]
    }
  end

  defp file_run!(probe) do
    fixture = file_fixture!()

    try do
      workspace = Workspace.new!(root: fixture.workspace, access: [:read])

      [
        {"parent_traversal", "../outside/canary.txt"},
        {"absolute_path", fixture.canary},
        {"file_symlink", "canary-link.txt"},
        {"directory_symlink", "outside-link/canary.txt"}
      ]
      |> Enum.map(fn {name, path} ->
        classification = classify_file_result(probe.(workspace, %{"path" => path}))

        if classification != "denied" do
          raise "file-boundary case #{name} expected denied but got #{classification}"
        end

        %{"name" => name, "classification" => classification}
      end)
    after
      File.rm_rf!(fixture.root)
    end
  end

  defp file_fixture! do
    root = temporary_path("jido-file-boundary")
    workspace = Path.join(root, "workspace")
    outside = Path.join(root, "outside")
    canary = Path.join(outside, "canary.txt")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)
    File.write!(canary, @canary)
    File.ln_s!(canary, Path.join(workspace, "canary-link.txt"))
    File.ln_s!(outside, Path.join(workspace, "outside-link"))
    %{root: root, workspace: workspace, canary: canary}
  end

  defp classify_file_result({:error, %Error{code: :workspace_path_rejected}}), do: "denied"
  defp classify_file_result({:ok, _result}), do: "known_risk"
  defp classify_file_result(result), do: raise("unsupported file-boundary result: #{inspect(result)}")

  defp loopback_accepted?(true), do: false

  defp loopback_accepted?(false) do
    receive do
      {:loopback_accepted, value} -> value
    after
      2_000 -> false
    end
  end

  defp network_probe! do
    nc = System.find_executable("nc") || raise "runtime-boundary checks require nc"
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()

    acceptor =
      Task.async(fn ->
        accepted? =
          case :gen_tcp.accept(listener, 2_000) do
            {:ok, socket} ->
              :gen_tcp.close(socket)
              true

            {:error, _reason} ->
              false
          end

        send(parent, {:loopback_accepted, accepted?})
      end)

    try do
      loopback = adapter_command!(nc, ["-w", "1", "-z", "127.0.0.1", Integer.to_string(port)], 2_000)
      accepted? = loopback_accepted?(loopback["status"] == "denied")
      external = adapter_command!(nc, ["-w", "1", "-z", "192.0.2.1", "9"], 2_000)

      [
        %{
          "name" => "loopback",
          "classification" => if(loopback["status"] == "ok" and accepted?, do: "known_risk", else: "denied")
        },
        %{
          "name" => "external",
          "classification" => if(external["status"] == "ok", do: "known_risk", else: "denied")
        }
      ]
    after
      :gen_tcp.close(listener)
      Task.shutdown(acceptor, :brutal_kill)
    end
  end

  defp process_probe! do
    Enum.map(~w(success rejection cancellation timeout owner_exit), &process_case!/1)
  end

  defp process_case!(name) do
    fixture = process_fixture!()

    try do
      outcome = execute_process_case!(name, fixture)
      child = read_child_pid!(fixture)
      product_stopped_child? = until(fn -> not process_alive?(child) end, 150)
      stop_process(child)

      unless until(fn -> not process_alive?(child) end, 500) do
        raise "runtime-boundary runner could not stop the #{name} child process"
      end

      %{
        "name" => name,
        "outcome" => outcome,
        "classification" => if(product_stopped_child?, do: "denied", else: "known_risk"),
        "runner_cleanup" => "passed"
      }
    after
      fixture |> read_child_pid() |> Enum.each(&stop_process/1)
      File.rm_rf!(fixture.root)
    end
  end

  defp execute_process_case!("owner_exit", fixture) do
    {owner, monitor} =
      spawn_monitor(fn ->
        adapter_command!(fixture.executable, ["owner_exit", fixture.state], 10_000,
          temporary_root: fixture.root,
          workspace_root: fixture.workspace
        )
      end)

    wait_for_child!(fixture)
    Process.exit(owner, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^owner, _reason} -> "owner_exit"
    after
      1_000 -> raise "runtime-boundary owner did not exit"
    end
  end

  defp execute_process_case!(name, fixture) do
    token = Token.new()
    timeout = if name == "timeout", do: 250, else: 5_000

    task =
      Task.async(fn ->
        adapter_command!(fixture.executable, [name, fixture.state], timeout,
          cancellation: token,
          temporary_root: fixture.root,
          workspace_root: fixture.workspace
        )
      end)

    wait_for_child!(fixture)
    if name == "cancellation", do: Token.request(token)
    result = Task.await(task, 6_000)
    result["status"]
  end

  defp adapter_command!(executable, args, timeout, extra_opts \\ []) do
    root = temporary_path("jido-runtime-boundary")
    File.mkdir_p!(root)
    workspace_root = Keyword.get(extra_opts, :workspace_root, root)
    adapter_opts = Keyword.delete(extra_opts, :workspace_root)

    try do
      workspace = Workspace.new!(root: workspace_root, access: [:shell])

      request = %{
        "command" => "git",
        "args" => args,
        "stdin" => "",
        "cwd" => ".",
        "timeout_ms" => timeout,
        "max_output_bytes" => 1_024,
        "network" => false,
        "command_class" => "git",
        "mutation" => "read"
      }

      opts =
        Keyword.merge(
          [
            workspace: workspace,
            executables: %{
              "git" => executable,
              "sandbox-exec" =>
                System.find_executable("sandbox-exec") || raise("runtime-boundary checks require sandbox-exec")
            }
          ],
          adapter_opts
        )

      case Adapter.execute(nil, request, opts) do
        {:ok, result, _evidence} -> result
        {:error, {:network_denied, decision}} -> %{"status" => "denied", "class" => Atom.to_string(decision.class)}
        {:error, reason} -> raise "runtime-boundary adapter failed: #{inspect(reason)}"
      end
    after
      File.rm_rf!(root)
    end
  end

  defp process_fixture! do
    root = temporary_path("jido-process-boundary")
    workspace = Path.join(root, "workspace")
    state = Path.join(workspace, "state")
    executable = Path.join(workspace, "process-fixture")
    File.mkdir_p!(state)

    File.write!(
      executable,
      """
      #!/bin/sh
      mode=$1
      state=$2
      sleep 30 </dev/null >/dev/null 2>&1 &
      child=$!
      printf '%s' "$child" > "$state/child.pid"
      case "$mode" in
        success) exit 0 ;;
        rejection) exit 23 ;;
        *) wait "$child" ;;
      esac
      """
    )

    File.chmod!(executable, 0o700)
    %{root: root, workspace: workspace, state: state, executable: executable}
  end

  defp wait_for_child!(fixture) do
    unless until(fn -> File.regular?(Path.join(fixture.state, "child.pid")) end, 1_000) do
      raise "runtime-boundary child process did not start"
    end
  end

  defp read_child_pid!(fixture) do
    case read_child_pid(fixture) do
      [pid] -> pid
      _other -> raise "runtime-boundary child process identifier is missing"
    end
  end

  defp read_child_pid(fixture) do
    case File.read(Path.join(fixture.state, "child.pid")) do
      {:ok, value} ->
        case Integer.parse(String.trim(value)) do
          {pid, ""} when pid > 1 -> [pid]
          _invalid -> []
        end

      {:error, _reason} ->
        []
    end
  end

  defp process_alive?(pid) do
    case System.cmd("/bin/ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {status, 0} -> not String.starts_with?(String.trim(status), "Z")
      {_output, _status} -> false
    end
  end

  defp stop_process(pid) do
    if process_alive?(pid), do: System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)])
    :ok
  end

  defp until(check, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_until(check, deadline)
  end

  defp do_until(check, deadline) do
    cond do
      check.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        do_until(check, deadline)
    end
  end

  defp validate_classes!(kind, results, expected) do
    Enum.each(results, fn result ->
      name = result["name"]
      actual = result["classification"]

      if expected[name] != actual do
        raise "runtime-boundary #{kind} case #{name} expected #{expected[name]} but got #{actual}"
      end
    end)
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp temporary_path(prefix) do
    id = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "#{prefix}-#{id}")
  end
end
