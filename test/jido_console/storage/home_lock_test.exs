defmodule Jido.Console.Storage.HomeLockTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Home
  alias Jido.Console.Storage.HomeLock

  setup do
    root = Path.join(System.tmp_dir!(), "jido-home-lock-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "a normal stop releases the exclusive lock", %{root: root} do
    assert {:ok, lock} = HomeLock.start_link(jido_home: root, name: unique(:first_lock))
    path = Path.join(root, "state/console-lock.sqlite3")
    assert File.regular?(path)
    assert :ok = Home.check_private(path)

    assert :ok = GenServer.stop(lock)
    refute Process.alive?(lock)

    assert {:ok, replacement} =
             HomeLock.start_link(jido_home: root, name: unique(:replacement_lock))

    assert :ok = GenServer.stop(replacement)
  end

  test "rejects a symbolic-link lock without changing its target", %{root: root} do
    assert {:ok, _home} = Home.ensure(jido_home: root)
    target = Path.join(root, "target")
    path = Path.join(root, "state/console-lock.sqlite3")
    File.write!(target, "keep")
    File.chmod!(target, Home.file_mode())
    File.ln_s!(target, path)

    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    assert {:error, {:unsafe_home_lock, ^path, :symlink}} =
             HomeLock.start_link(jido_home: root, name: unique(:unsafe_lock))

    assert File.read!(target) == "keep"
    assert {:ok, %{type: :symlink}} = File.lstat(path)
  end

  defp unique(label), do: String.to_atom("#{label}-#{System.unique_integer([:positive])}")
end
