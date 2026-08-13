defmodule Jido.Cli.Release.ToolingTest do
  use ExUnit.Case, async: false

  alias Jido.Cli.Release.{Acceptance, Artifact, LicenseAudit, Local, OfflineProfile, ProbeRuntime}
  alias Jido.Cli.Automation.Replay

  setup do
    root = Path.join(System.tmp_dir!(), "jido-release-tooling-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "computes stable startup statistics with a separate cold result" do
    values = [900, 100, 120, 110, 130]

    assert Acceptance.statistics!(values) == %{
             "cold_ms" => 900.0,
             "warm_runs" => 4,
             "warm_median_ms" => 115.0,
             "warm_p95_ms" => 130.0,
             "warm_samples_ms" => [100.0, 120.0, 110.0, 130.0]
           }
  end

  test "detects a changed file digest", %{root: root} do
    path = Path.join(root, "artifact")
    File.write!(path, "first")
    first = Artifact.sha256_file(path)
    File.write!(path, "second")
    second = Artifact.sha256_file(path)

    assert byte_size(first) == 64
    assert byte_size(second) == 64
    refute first == second
  end

  test "rejects dirty publication and permits an explicit development override" do
    assert_raise RuntimeError, ~r/worktree is dirty/, fn ->
      Local.validate_source!(%{dirty: true}, false)
    end

    assert :ok = Local.validate_source!(%{dirty: true}, true)
    assert :ok = Local.validate_source!(%{dirty: false}, false)
  end

  test "creates deterministic reviewed notice records", %{root: root} do
    license = Path.join(root, "LICENSE")
    File.write!(license, "license text\n")

    component = %{
      name: "sample",
      version: "1.0.0",
      kind: :dependency,
      source: "hex://hexpm/sample@1.0.0",
      licenses: ["MIT"],
      license_file: "deps/sample/LICENSE",
      license_path: license,
      native_files: ["priv/sample.dylib"]
    }

    first = LicenseAudit.notices([component])
    assert first == LicenseAudit.notices([component])
    assert first =~ "sample 1.0.0"
    assert first =~ "priv/sample.dylib"
    assert first =~ "license text"
  end

  test "the embedded release profile resolves a pinned provider-free replay" do
    assert {:ok, registration} = OfflineProfile.resolve(%{profile_id: "offline-example"}, [])
    assert {:ok, %{mode: :replay} = replay} = Replay.resolve(%{registration: registration})
    assert replay.fixture.digest == "sha256:cace48232cdf26c6b325a45a1a0074cf1994e719b09eca534e29f2c7793636b8"

    assert {:error, {:unknown_runtime_profile, "other"}} =
             OfflineProfile.resolve(%{profile_id: "other"}, [])
  end

  test "the TUI release probe records one turn", %{root: root} do
    log = Path.join(root, "turns.log")
    previous = System.get_env("JIDO_RELEASE_TUI_PROBE_LOG")
    System.put_env("JIDO_RELEASE_TUI_PROBE_LOG", log)

    on_exit(fn ->
      if previous,
        do: System.put_env("JIDO_RELEASE_TUI_PROBE_LOG", previous),
        else: System.delete_env("JIDO_RELEASE_TUI_PROBE_LOG")
    end)

    assert {:ok, request} = ProbeRuntime.start_turn(:release_probe_session, "hello", self(), [])
    assert_receive {:jidoka_turn_event, _event}
    assert_receive {:jidoka_turn_event, _event}
    assert {:ok, :release_probe_session, "Release probe completed."} = ProbeRuntime.await(request, [])
    assert [_one_turn] = log |> File.read!() |> String.split("\n", trim: true)
  end
end
