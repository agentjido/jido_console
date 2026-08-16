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

  test "reports invalid migration, restore, backup, and removal inputs", %{root: root, opts: opts} do
    assert Lifecycle.confirmation_tokens() == %{
             disposable: :remove_disposable,
             retained: :remove_retained_user_data
           }

    missing = Path.join(root, "missing-cache")
    assert {:ok, _result} = Lifecycle.migrate(opts ++ [previous_cache_root: missing])

    source_file = Path.join(root, "cache-file")
    File.write!(source_file, "not a directory")

    assert {:error, {:migration_source_not_directory, ^source_file, :regular}} =
             Lifecycle.migrate(opts ++ [previous_cache_root: source_file])

    assert {:error, {:backup_not_directory, ^source_file, :regular}} =
             Lifecycle.restore(source_file, opts)

    empty_destination = Path.join(root, "empty-backup")
    File.mkdir_p!(empty_destination)
    assert {:ok, _result} = Lifecycle.backup(empty_destination, opts)

    destination_file = Path.join(root, "backup-file")
    File.write!(destination_file, "not a directory")

    assert {:error, {:backup_destination_not_directory, ^destination_file, :regular}} =
             Lifecycle.backup(destination_file, opts)

    assert {:error, {:invalid_removal_confirmation, :wrong}} =
             Lifecycle.remove(opts ++ [confirm: :wrong])

    absent_home = [jido_home: Path.join(root, "absent-home"), confirm: :remove_retained_user_data]
    assert {:ok, %{removed: removed}} = Lifecycle.remove(absent_home)
    assert Enum.sort(removed) == [:artifacts, :cache, :logs, :run, :state]
  end

  test "reports invalid entries while it copies retained data", %{root: root, opts: opts} do
    assert {:ok, _home} = Home.ensure(opts)
    {:ok, state} = Home.path(:state, opts)

    File.rmdir!(state)
    File.write!(state, "not a directory")

    assert {:error, {:backup_entry_not_directory, ^state, :regular}} =
             Lifecycle.backup(Path.join(root, "file-entry-backup"), opts)

    File.rm!(state)
    File.mkdir_p!(state)
    link = Path.join(state, "link")
    File.ln_s!("missing-target", link)

    assert {:error, {:unsupported_home_entry, ^link, :symlink}} =
             Lifecycle.backup(Path.join(root, "link-entry-backup"), opts)

    File.rm!(link)
    nested = Path.join(state, "nested")
    File.mkdir_p!(nested)
    File.write!(Path.join(nested, "value"), "private")
    File.chmod!(Path.join(nested, "value"), 0o600)

    assert {:ok, result} = Lifecycle.backup(Path.join(root, "nested-backup"), opts)
    assert "state" in result.entries
  end
end
