defmodule Jido.Console.HomeTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Home

  setup do
    root = Path.join(System.tmp_dir!(), "jido-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "JIDO_HOME selects the complete product home", %{root: root} do
    home_root = Path.join(root, "custom-home")
    assert {:ok, home} = Home.resolve(jido_home: home_root)
    assert home.root == home_root
    assert home.source == :jido_home
    assert home.schema == "jido.home"

    Enum.each([:state, :logs, :artifacts, :cache, :run], fn id ->
      assert {:ok, path} = Home.path(id, jido_home: home_root)
      assert String.starts_with?(path, home_root <> "/")
    end)
  end

  test "default home is ~/.jido", %{root: root} do
    user_home = Path.join(root, "user")
    File.mkdir_p!(user_home)
    assert {:ok, home} = Home.resolve(jido_home: nil, user_home: user_home)
    assert home.root == Path.join(user_home, ".jido")
    assert home.source == :default
  end

  test "each stable directory has one owner and purpose" do
    assert Home.schema() == "jido.home"
    assert Home.schema_version() == 1
    assert is_binary(Home.previous_cache_root())

    directories = Home.directories()

    assert Map.keys(directories) |> Enum.sort() ==
             [:artifacts, :cache, :logs, :run, :state]

    Enum.each(directories, fn {id, directory} ->
      assert directory.id == id
      assert directory.relative == Atom.to_string(id)
      assert is_binary(directory.purpose) and directory.purpose != ""
      assert directory.owner in [:product, :diagnostics, :artifacts, :cache, :process]
      assert directory.class in [:retained, :disposable]
    end)

    assert directories.state.class == :retained
    assert directories.cache.class == :disposable
    assert directories.run.class == :disposable
  end

  test "ensure creates private directories and rejects unsafe permissions", %{root: root} do
    home_root = Path.join(root, "safe")
    assert {:ok, home} = Home.ensure(jido_home: home_root)
    assert {:ok, %{type: :directory, mode: mode}} = File.lstat(home.root)
    assert Bitwise.band(mode, 0o077) == 0

    Enum.each(Map.values(home.directories), fn directory ->
      path = Path.join(home.root, directory.relative)
      assert {:ok, %{type: :directory, mode: dir_mode}} = File.lstat(path)
      assert Bitwise.band(dir_mode, 0o077) == 0
    end)

    unsafe = Path.join(root, "unsafe")
    File.mkdir_p!(unsafe)
    File.chmod!(unsafe, 0o755)
    assert {:error, {:unsafe_permissions, ^unsafe, _mode}} = Home.ensure(jido_home: unsafe)
  end

  test "in_home? does not treat unrelated host paths as product paths", %{root: root} do
    home_root = Path.join(root, "home")
    File.mkdir_p!(home_root)
    refute Home.in_home?(Path.join(root, "other"), jido_home: home_root)
    assert Home.in_home?(Path.join(home_root, "cache"), jido_home: home_root)
  end

  test "reports missing, unsafe, and non-directory home paths", %{root: root} do
    missing = Path.join(root, "missing")
    assert {:error, {:home_stat_failed, ^missing, :enoent}} = Home.check_private(missing)

    unsafe = Path.join(root, "unsafe-check")
    File.mkdir_p!(unsafe)
    File.chmod!(unsafe, 0o755)
    assert {:error, {:unsafe_permissions, ^unsafe, _mode}} = Home.check_private(unsafe)

    home_file = Path.join(root, "home-file")
    File.write!(home_file, "not a directory")
    assert {:error, {:home_path_not_directory, ^home_file, :regular}} = Home.ensure(jido_home: home_file)

    home_root = Path.join(root, "named-entry")
    assert {:ok, _home} = Home.ensure(jido_home: home_root)
    state = Path.join(home_root, "state")
    File.rmdir!(state)
    File.write!(state, "not a directory")

    assert {:error, {:home_path_not_directory, ^state, :regular}} =
             Home.ensure(jido_home: home_root)
  end

  test "production local product paths resolve through the home contract" do
    root = Path.expand("../..", __DIR__)

    matches =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> then(&Regex.scan(~r/:filename\.basedir\(:user_cache/, &1))
        |> Enum.map(fn [hit] -> {Path.relative_to(path, root), hit} end)
      end)

    assert matches == [{"lib/jido_console/home.ex", ":filename.basedir(:user_cache"}]
  end
end
