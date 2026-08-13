defmodule Jido.Cli.BootstrapTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Bootstrap

  setup do
    root = Path.join(System.tmp_dir!(), "jido-bootstrap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    script = Path.join(root, "jido")
    File.write!(script, "fixture escript")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, script: script}
  end

  test "uses an available private directory without extraction" do
    priv = Path.join(System.tmp_dir!(), "jido-bootstrap-priv-#{System.unique_integer([:positive])}")
    File.mkdir_p!(priv)
    on_exit(fn -> File.rm_rf!(priv) end)

    assert :ok = Bootstrap.make_priv_files_accessible(priv_dir: fn :time_zone_info -> String.to_charlist(priv) end)
  end

  test "extracts into a private content-addressed cache and reuses it", %{root: root, script: script} do
    test_pid = self()
    unzip = fixture_unzip(test_pid)

    opts = [
      priv_dir: fn :time_zone_info -> {:error, :bad_name} end,
      script_name: fn -> script end,
      cache_root: Path.join(root, "cache"),
      version: "test",
      otp_release: "test",
      extract: fn _path, [] -> {:ok, archive: :fixture} end,
      unzip: unzip
    ]

    assert :ok = Bootstrap.make_priv_files_accessible(opts)
    assert_receive :unzipped

    [cache] = Path.wildcard(Path.join(root, "cache/escript/test-otp-test-*"))
    assert {:ok, %{mode: cache_mode}} = File.stat(cache)
    assert Bitwise.band(cache_mode, 0o077) == 0

    marker = Path.join(cache, ".complete")
    assert {:ok, %{mode: marker_mode}} = File.stat(marker)
    assert Bitwise.band(marker_mode, 0o077) == 0
    assert File.read!(marker) =~ "fixture/ebin"

    assert :ok =
             Bootstrap.make_priv_files_accessible(
               Keyword.put(opts, :extract, fn _path, [] -> flunk("cache was not reused") end)
             )

    refute_receive :unzipped
    :code.del_path(String.to_charlist(Path.join(cache, "fixture/ebin")))
  end

  test "rejects a tampered cache marker and an unsafe cache root", %{root: root, script: script} do
    opts = [
      priv_dir: fn :time_zone_info -> {:error, :bad_name} end,
      script_name: fn -> script end,
      cache_root: Path.join(root, "cache"),
      version: "test",
      otp_release: "test",
      extract: fn _path, [] -> {:ok, archive: :fixture} end,
      unzip: fixture_unzip(self())
    ]

    assert :ok = Bootstrap.make_priv_files_accessible(opts)
    assert_receive :unzipped
    [cache] = Path.wildcard(Path.join(root, "cache/escript/test-otp-test-*"))
    File.write!(Path.join(cache, ".complete"), "wrong\nfixture/ebin\n")

    assert {:error, :escript_cache_marker_invalid} = Bootstrap.make_priv_files_accessible(opts)

    unsafe = Path.join(root, "unsafe")
    File.write!(unsafe, "not a directory")

    assert {:error, {:unsafe_cache_path, ^unsafe}} =
             Bootstrap.make_priv_files_accessible(Keyword.put(opts, :cache_root, unsafe))
  end

  test "starts the application only after private files are available" do
    test_pid = self()
    priv = Path.join(System.tmp_dir!(), "jido-bootstrap-start-#{System.unique_integer([:positive])}")
    File.mkdir_p!(priv)
    on_exit(fn -> File.rm_rf!(priv) end)

    assert :ok =
             Bootstrap.start_applications(
               priv_dir: fn :time_zone_info -> String.to_charlist(priv) end,
               ensure_all_started: fn :jido_cli ->
                 send(test_pid, :started)
                 {:ok, [:jido_cli]}
               end
             )

    assert_receive :started
  end

  defp fixture_unzip(test_pid) do
    fn :fixture, opts ->
      cwd = opts |> Keyword.fetch!(:cwd) |> List.to_string()
      ebin = Path.join(cwd, "fixture/ebin")
      File.mkdir_p!(ebin)
      File.write!(Path.join(ebin, "fixture.beam"), "beam")
      send(test_pid, :unzipped)
      {:ok, [String.to_charlist(Path.join(ebin, "fixture.beam"))]}
    end
  end
end
