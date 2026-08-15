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

    assert {:ok, install} = Channel.install(:archive, payload, prefix, public_key: key.public)
    assert install.version == "0.1.0"
    assert {:ok, first} = Channel.first_run(install)
    assert first["compiled"] == false
    assert first["toolchain"] == "bundled"
    assert first["executable"] == "bin/jido"

    assert {:error, :trusted_public_key_required} = Channel.install(:archive, payload, Path.join(prefix, "no-key"))

    assert {:ok, updated} = Channel.update(install, payload, public_key: key.public)
    assert updated.payload_sha256 == install.payload_sha256

    assert {:ok, removed} = Channel.remove(updated, user_data: ["user-data"])
    assert File.exists?(Path.join(prefix, "user-data/.keep"))
    refute File.exists?(Path.join(prefix, "release.json"))
    assert removed["user_data"] == ["user-data"]

    report = Channel.evidence(:archive, [first, removed])
    assert report["published"] == false
    refute inspect(report) =~ "sk-"
  end

  test "rejects a changed archive before installation", %{payload: payload, prefix: prefix, key: key} do
    File.write!(Path.join(payload, "jido-0.1.0-darwin-arm64.tar.gz"), "tampered")
    assert {:error, {:checksum_mismatch, _name}} = Channel.install(:archive, payload, prefix, public_key: key.public)
    refute File.exists?(Path.join(prefix, "release.json"))
  end
end
