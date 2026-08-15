defmodule Jido.Console.Home.LifecycleTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Home
  alias Jido.Console.Home.Lifecycle

  setup do
    root = Path.join(System.tmp_dir!(), "jido-home-life-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, opts: [jido_home: Path.join(root, "home")]}
  end

  test "migration copies the previous cache and keeps the source", %{root: root, opts: opts} do
    source = Path.join(root, "legacy-cache")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "marker"), "legacy")
    File.chmod!(Path.join(source, "marker"), 0o600)

    assert {:ok, result} = Lifecycle.migrate(opts ++ [previous_cache_root: source])
    assert File.read!(Path.join(result.destination, "marker")) == "legacy"
    assert File.read!(Path.join(source, "marker")) == "legacy"
    refute result.source_deleted?

    assert {:ok, _again} = Lifecycle.migrate(opts ++ [previous_cache_root: source])
  end

  test "migration reports a verification failure without deleting the source", %{
    root: root,
    opts: opts
  } do
    source = Path.join(root, "legacy-cache")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "marker"), "legacy")

    assert {:error, :forced} =
             Lifecycle.migrate(
               opts ++
                 [
                   previous_cache_root: source,
                   verify: fn _source, _destination -> {:error, :forced} end
                 ]
             )

    assert File.exists?(Path.join(source, "marker"))
  end

  test "backup and restore preserve retained data", %{root: root, opts: opts} do
    assert {:ok, _} = Home.ensure(opts)
    {:ok, state} = Home.path(:state, opts)
    {:ok, cache} = Home.path(:cache, opts)
    File.write!(Path.join(state, "settings.json"), ~s({"theme":"dark"}))
    File.chmod!(Path.join(state, "settings.json"), 0o600)
    File.write!(Path.join(cache, "tmp"), "scratch")

    backup = Path.join(root, "backup")
    assert {:ok, backed} = Lifecycle.backup(backup, opts)
    assert "state" in backed.entries
    refute File.exists?(Path.join(backup, "cache"))
    assert File.read!(Path.join([backup, "state", "settings.json"])) == ~s({"theme":"dark"})

    File.rm!(Path.join(state, "settings.json"))
    assert {:ok, _} = Lifecycle.restore(backup, opts)
    assert File.read!(Path.join(state, "settings.json")) == ~s({"theme":"dark"})
  end

  test "backup reports a non-empty destination", %{root: root, opts: opts} do
    assert {:ok, _} = Home.ensure(opts)
    dest = Path.join(root, "backup")
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "keep"), "data")

    assert {:error, {:backup_destination_not_empty, ^dest, ["keep"]}} =
             Lifecycle.backup(dest, opts)
  end

  test "update keeps data and does not widen permissions", %{opts: opts} do
    assert {:ok, home} = Home.ensure(opts)
    {:ok, state} = Home.path(:state, opts)
    File.write!(Path.join(state, "keep"), "data")
    File.chmod!(Path.join(state, "keep"), 0o600)

    assert {:ok, updated} = Lifecycle.update(opts)
    assert updated.home == home.root
    assert File.read!(Path.join(state, "keep")) == "data"
    assert {:ok, %{mode: mode}} = File.lstat(home.root)
    assert Bitwise.band(mode, 0o077) == 0
  end

  test "removal requires confirmation and keeps retained user data", %{opts: opts} do
    assert {:ok, _} = Home.ensure(opts)
    {:ok, state} = Home.path(:state, opts)
    {:ok, cache} = Home.path(:cache, opts)
    File.write!(Path.join(state, "keep"), "user")
    File.write!(Path.join(cache, "tmp"), "scratch")

    assert {:error, :removal_confirmation_required} = Lifecycle.remove(opts)

    assert {:ok, result} = Lifecycle.remove(opts ++ [confirm: :remove_disposable])
    assert :cache in result.removed
    assert :state in result.retained
    refute File.exists?(cache)
    assert File.read!(Path.join(state, "keep")) == "user"

    assert {:ok, emptied} = Lifecycle.remove(opts ++ [confirm: :remove_retained_user_data])
    assert :state in emptied.removed
    refute File.exists?(state)
  end
end
