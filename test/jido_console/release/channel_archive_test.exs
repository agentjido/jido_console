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
end
