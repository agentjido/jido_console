defmodule Jido.Console.Release.ChannelArchiveTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.{Channel, PayloadFixture}

  setup do
    root = Path.join(System.tmp_dir!(), "jido-archive-#{System.unique_integer([:positive])}")
    payload = Path.join(root, "payload")
    prefix = Path.join(root, "prefix")
    File.mkdir_p!(payload)
    fixture = PayloadFixture.create(payload)
    on_exit(fn -> File.rm_rf!(root) end)
    %{payload: payload, prefix: prefix, key: fixture.key}
  end

  test "installs a verified archive and completes the lifecycle", %{payload: payload, prefix: prefix, key: key} do
    File.mkdir_p!(Path.join(prefix, "user-data"))
    File.write!(Path.join(prefix, "user-data/.keep"), "keep")

    result = Channel.lifecycle(payload, prefix, public_key: key.public, user_data: ["user-data"])
    assert :ok = Channel.validate_result(result, :archive)
    assert result["status"] == "pass"
    assert result["payload_identity"]["version"] == "0.1.0"
    assert result["payload_identity"]["license"] == "Apache-2.0"
    assert byte_size(result["payload_identity"]["checksum"]) == 64
    assert result["payload_identity"]["provenance"] == %{}

    assert Enum.map(result["stages"], & &1["stage"]) == ~w(install first_run update remove)
    assert Enum.all?(result["stages"], &(&1["status"] == "pass"))
    first = Enum.find(result["stages"], &(&1["stage"] == "first_run"))
    removed = Enum.find(result["stages"], &(&1["stage"] == "remove"))
    assert first["compiled"] == false
    assert first["toolchain"] == "bundled"
    assert first["executable"] == "bin/jido"

    assert File.exists?(Path.join(prefix, "user-data/.keep"))
    refute File.exists?(Path.join(prefix, "release.json"))
    assert removed["user_data"] == ["user-data"]
    assert result["published"] == false
    refute inspect(result) =~ "sk-"

    assert {:error, :invalid_channel_result} =
             Channel.validate_result(%{result | "stages" => tl(result["stages"])}, :archive)

    no_key = Channel.lifecycle(payload, Path.join(prefix, "no-key"))
    assert no_key["status"] == "fail"
    assert Enum.map(no_key["stages"], & &1["status"]) == ["fail", "not_run", "not_run", "not_run"]
  end

  test "rejects a changed archive before installation", %{payload: payload, prefix: prefix, key: key} do
    File.write!(Path.join(payload, "jido-0.1.0-darwin-arm64.tar.gz"), "tampered")
    result = Channel.lifecycle(payload, prefix, public_key: key.public)
    assert result["status"] == "fail"
    assert hd(result["stages"])["stage"] == "install"
    assert hd(result["stages"])["reason"] =~ "checksum_mismatch"
    refute File.exists?(Path.join(prefix, "release.json"))
  end

  test "normalizes each owner callback failure and validates strict results" do
    identity = %{
      "checksum" => "checksum",
      "provenance" => %{},
      "version" => "1.0.0",
      "license" => "Apache-2.0"
    }

    install = %{root: "/tmp", executable: "/bin/true", payload_identity: identity}
    pass = fn stage -> %{"stage" => Atom.to_string(stage), "status" => "pass"} end

    callbacks = [
      {:install, fn -> {:error, :install} end, fn _ -> {:ok, pass.(:first_run)} end,
       fn value -> {:ok, value, pass.(:update)} end, fn _ -> {:ok, pass.(:remove)} end},
      {:first_run, fn -> {:ok, install, pass.(:install)} end, fn _ -> {:error, :first_run} end,
       fn value -> {:ok, value, pass.(:update)} end, fn _ -> {:ok, pass.(:remove)} end},
      {:update, fn -> {:ok, install, pass.(:install)} end, fn _ -> {:ok, pass.(:first_run)} end,
       fn _ -> {:error, :update} end, fn _ -> {:ok, pass.(:remove)} end},
      {:remove, fn -> {:ok, install, pass.(:install)} end, fn _ -> {:ok, pass.(:first_run)} end,
       fn value -> {:ok, value, pass.(:update)} end, fn _ -> {:error, :remove} end}
    ]

    for {failed_stage, install_callback, first_run, update, remove} <- callbacks do
      result = Channel.execute(:archive, {:ok, identity}, install_callback, first_run, update, remove)
      assert result["status"] == "fail"
      assert Enum.find(result["stages"], &(&1["stage"] == Atom.to_string(failed_stage)))["status"] == "fail"
      assert :ok = Channel.validate_result(result, :archive)
    end

    unavailable = Channel.execute(:archive, {:error, :identity}, fn -> flunk("not called") end, nil, nil, nil)
    assert unavailable["payload_identity"]["version"] == "unavailable"
    assert :ok = Channel.validate_result(unavailable, :archive)

    invalid_results = [
      :invalid,
      %{unavailable | "channel" => "npm"},
      %{unavailable | "payload_identity" => %{}},
      %{unavailable | "status" => "pass"},
      %{unavailable | "stages" => [%{"stage" => "install", "status" => "other"}]}
    ]

    for invalid <- invalid_results do
      assert {:error, :invalid_channel_result} = Channel.validate_result(invalid, :archive)
    end
  end

  test "reports incomplete identity, first-run, and removal errors", %{payload: payload, prefix: prefix} do
    File.write!(Path.join(payload, "payload.json"), Jason.encode!(%{"archive" => nil}))
    assert {:error, :payload_identity_incomplete} = Channel.identity(payload)

    executable = Path.join(prefix, "jido")
    File.mkdir_p!(prefix)
    File.write!(executable, "#!/bin/sh\necho failed\nexit 4\n")
    File.chmod!(executable, 0o755)
    install = %{root: prefix, executable: executable, payload_identity: %{"version" => "1.0.0"}}
    assert {:error, {:first_run_failed, 4, _}} = Channel.first_run(install)

    File.write!(executable, "#!/bin/sh\necho 2.0.0\n")
    File.chmod!(executable, 0o755)
    assert {:error, :version_mismatch} = Channel.first_run(install)
    assert {:error, :enoent} = Channel.remove(%{install | root: Path.join(prefix, "absent")})
  end
end
