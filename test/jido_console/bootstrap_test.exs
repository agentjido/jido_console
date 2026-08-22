defmodule Jido.Console.BootstrapTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Bootstrap

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
      progress: fn event -> send(test_pid, {:progress, event}) end,
      extract: fn _path, [] -> {:ok, archive: :fixture} end,
      unzip: unzip
    ]

    assert :ok = Bootstrap.make_priv_files_accessible(opts)
    assert_receive {:progress, :extracting_escript}
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
               opts
               |> Keyword.put(:progress, fn event -> flunk("cache reuse reported #{inspect(event)}") end)
               |> Keyword.put(:extract, fn _path, [] -> flunk("cache was not reused") end)
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

  test "extracts into the Jido home cache when no cache root is injected", %{root: root, script: script} do
    home = Path.join(root, "jido-home")

    opts = [
      priv_dir: fn :time_zone_info -> {:error, :bad_name} end,
      script_name: fn -> script end,
      jido_home: home,
      version: "test",
      otp_release: "test",
      extract: fn _path, [] -> {:ok, archive: :fixture} end,
      unzip: fixture_unzip(self())
    ]

    assert :ok = Bootstrap.make_priv_files_accessible(opts)
    assert_receive :unzipped
    assert [cache] = Path.wildcard(Path.join(home, "cache/escript/test-otp-test-*"))
    assert File.dir?(cache)
  end

  test "starts the application only after private files are available" do
    test_pid = self()
    priv = Path.join(System.tmp_dir!(), "jido-bootstrap-start-#{System.unique_integer([:positive])}")
    File.mkdir_p!(priv)
    on_exit(fn -> File.rm_rf!(priv) end)

    home = Path.join(System.tmp_dir!(), "jido-bootstrap-home-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(home) end)

    add_filter = fn id, {filter, config} ->
      send(test_pid, {:logger_filter, id, filter, config})
      :ok
    end

    assert :ok =
             Bootstrap.start_applications(
               priv_dir: fn :time_zone_info -> String.to_charlist(priv) end,
               jido_home: home,
               name: :"jido-bootstrap-proc-#{System.unique_integer([:positive])}",
               add_primary_logger_filter: add_filter,
               ensure_all_started: fn :jido_console ->
                 send(test_pid, :started)
                 {:ok, [:jido_console]}
               end
             )

    assert_receive {:logger_filter, :jido_console_optional_native_load, filter, config}
    assert filter.(extractous_load_warning(), config) == :stop
    assert filter.(put_in(extractous_load_warning(), [:level], :error), config) == :ignore
    assert_receive :started
  end

  test "normalizes logger filter installation outcomes" do
    priv = Path.join(System.tmp_dir!(), "jido-bootstrap-filter-#{System.unique_integer([:positive])}")
    File.mkdir_p!(priv)
    on_exit(fn -> File.rm_rf!(priv) end)

    base = [
      priv_dir: fn :time_zone_info -> String.to_charlist(priv) end,
      ensure_all_started: fn :jido_console -> {:ok, [:jido_console]} end
    ]

    assert :ok =
             Bootstrap.start_applications(
               Keyword.put(base, :add_primary_logger_filter, fn id, _filter ->
                 {:error, {:already_exist, id}}
               end)
             )

    assert {:error, {:logger_filter_install_failed, :not_supported}} =
             Bootstrap.start_applications(
               Keyword.put(base, :add_primary_logger_filter, fn _id, _filter ->
                 {:error, :not_supported}
               end)
             )
  end

  test "rejects invalid progress and an archive without code paths", %{root: root, script: script} do
    base = [
      priv_dir: fn :time_zone_info -> {:error, :bad_name} end,
      script_name: fn -> script end,
      cache_root: Path.join(root, "cache"),
      version: "test",
      otp_release: "test",
      extract: fn _path, [] -> {:ok, archive: :fixture} end
    ]

    assert {:error, :invalid_bootstrap_progress} =
             Bootstrap.make_priv_files_accessible(Keyword.put(base, :progress, :invalid))

    assert {:error, :escript_cache_has_no_code_paths} =
             Bootstrap.make_priv_files_accessible(Keyword.put(base, :unzip, fn :fixture, _opts -> {:ok, []} end))
  end

  test "rejects unsafe or incomplete cache filesystem state", %{root: root, script: script} do
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
    [digest | _paths] = cache |> Path.join(".complete") |> File.read!() |> String.split("\n", trim: true)

    File.rm_rf!(cache)
    File.write!(cache, "unsafe")
    assert {:error, :escript_cache_is_not_a_directory} = Bootstrap.make_priv_files_accessible(opts)

    File.rm!(cache)
    File.mkdir!(cache)
    File.chmod!(cache, 0o755)
    assert {:error, :escript_cache_is_not_private_or_complete} = Bootstrap.make_priv_files_accessible(opts)

    File.chmod!(cache, 0o700)
    marker = Path.join(cache, ".complete")
    File.mkdir!(marker)
    assert {:error, :escript_cache_is_not_a_directory} = Bootstrap.make_priv_files_accessible(opts)

    File.rmdir!(marker)

    assert {:error, {:escript_cache_invalid, :enoent}} =
             Bootstrap.make_priv_files_accessible(opts)

    File.write!(marker, digest <> "\nfixture/ebin\n")
    File.chmod!(marker, 0o600)
    assert {:error, :escript_cache_is_not_private_or_complete} = Bootstrap.make_priv_files_accessible(opts)
  end

  test "reports an unavailable cache path below a regular file", %{root: root, script: script} do
    blocked = Path.join(root, "blocked")
    cache_root = Path.join(blocked, "cache")
    File.write!(blocked, "not a directory")

    assert {:error, {:cache_directory_unavailable, ^cache_root, :enotdir}} =
             Bootstrap.make_priv_files_accessible(
               priv_dir: fn :time_zone_info -> {:error, :bad_name} end,
               script_name: fn -> script end,
               cache_root: cache_root,
               version: "test",
               otp_release: "test"
             )
  end

  defp extractous_load_warning do
    %{
      level: :warning,
      msg:
        {:report,
         %{
           args: [ExtractousEx.Native, {:error, :nif_not_loaded}, 10],
           label: {:error_logger, :warning_msg},
           format: ~c"The on_load function for module ~s returned:~n~P\n"
         }},
      meta: %{}
    }
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
