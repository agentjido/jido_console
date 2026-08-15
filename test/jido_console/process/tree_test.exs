defmodule Jido.Console.Process.TreeTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Process.Tree
  alias Jido.Console.Release.Boundaries

  test "stops a grandchild left behind by the group leader" do
    {leader, child} = spawn_group_with_child!()
    assert Tree.alive?(child)

    assert {:ok, result} = Tree.stop(leader)
    assert result.status == :stopped
    assert result.leftover == 0
    assert Tree.evidence(result) == %{"status" => "stopped", "cleanup" => "confirmed"}
    refute Tree.alive?(leader)
    refute Tree.alive?(child)
    refute inspect(Tree.evidence(result)) =~ Integer.to_string(child)
  end

  test "owner exit stops the remaining child tree" do
    parent = self()

    owner =
      spawn(fn ->
        {leader, child} = spawn_group_with_child!(register_exit: false)
        _watch = Tree.watch(leader)
        send(parent, {:started, leader, child})
        Process.sleep(:infinity)
      end)

    assert_receive {:started, leader, child}, 1_000
    on_exit(fn -> Tree.stop(leader) end)
    assert Tree.alive?(child)
    Process.exit(owner, :kill)

    assert until(fn -> not Tree.alive?(child) end, 500)
    refute Tree.alive?(leader)
  end

  test "failed cleanup is visible and does not claim success" do
    assert {:error, :invalid_process_tree} = Tree.stop(1)

    assert Tree.evidence(%{status: :failed, leftover: 2}) == %{
             "status" => "failed",
             "cleanup" => "failed"
           }
  end

  test "removes process-local temporary state after cleanup" do
    root = Path.join(System.tmp_dir!(), "jido-tree-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "state"))
    assert :ok = Tree.cleanup_temp(root)
    refute File.dir?(root)
  end

  test "Gate 0 hostile runtime-boundary process fixtures are denied" do
    result =
      Boundaries.runtime_boundary!(
        network_probe: fn ->
          [
            %{"name" => "loopback", "classification" => "denied"},
            %{"name" => "external", "classification" => "denied"}
          ]
        end
      )

    assert result["status"] == "passed"
    assert Enum.all?(result["processes"], &(&1["classification"] == "denied"))
    assert Enum.all?(result["processes"], &(&1["runner_cleanup"] == "passed"))
    refute inspect(result) =~ ~r/"(?:pid|child_pid|parent_pid)"/
  end

  defp spawn_group_with_child!(opts \\ []) do
    state = Path.join(System.tmp_dir!(), "jido-tree-state-#{System.unique_integer([:positive])}")
    File.mkdir_p!(state)
    child_file = Path.join(state, "child.pid")

    {:ok, {perl, args}} =
      Tree.wrap_leader("/bin/sh", [
        "-c",
        "sleep 30 & printf '%s' $! > \"$1\"; wait",
        "tree-fixture",
        child_file
      ])

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(perl)},
        [:binary, :exit_status, :hide, args: args]
      )

    {:os_pid, leader} = Port.info(port, :os_pid)
    child = wait_pid_file!(child_file)
    if Keyword.get(opts, :register_exit, true), do: on_exit(fn -> Tree.stop(leader) end)
    {leader, child}
  end

  defp wait_pid_file!(path) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_wait_pid_file!(path, deadline)
  end

  defp do_wait_pid_file!(path, deadline) do
    case File.read(path) do
      {:ok, value} ->
        case Integer.parse(String.trim(value)) do
          {pid, ""} when pid > 1 -> pid
          _invalid -> retry_pid_file!(path, deadline)
        end

      {:error, _reason} ->
        retry_pid_file!(path, deadline)
    end
  end

  defp retry_pid_file!(path, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("child process identifier was not written")
    else
      Process.sleep(10)
      do_wait_pid_file!(path, deadline)
    end
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
end
