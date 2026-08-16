defmodule Jido.Console.Release.PayloadTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.Payload

  setup do
    root = Path.join(System.tmp_dir!(), "jido-payload-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "jido-0.1.0-darwin-arm64.tar.gz"), "archive-bytes")
    File.write!(Path.join(root, "LICENSE"), "Apache License Version 2.0")

    File.write!(
      Path.join(root, "release.json"),
      Jason.encode!(%{"version" => "0.1.0", "license" => "Apache-2.0", "target" => "darwin-arm64"}) <> "\n"
    )

    File.write!(Path.join(root, "sbom.json"), Jason.encode!(%{"bomFormat" => "CycloneDX", "version" => 1}) <> "\n")
    File.write!(Path.join(root, "provenance.json"), Jason.encode!(%{"schema" => "jido.provenance"}) <> "\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "seals a payload and verifies the approved key", %{root: root} do
    key = Payload.generate_key()
    archive = Path.join(root, "jido-0.1.0-darwin-arm64.tar.gz")
    assert {:ok, report} = Payload.seal(root, archive: archive, keypair: key)
    assert report["published"] == false
    assert report["version"] == "0.1.0"
    assert File.read!(Path.join(root, "checksums.txt")) =~ "release.json"

    assert {:ok, verified} = Payload.verify(root, public_key: key.public)
    assert {:ok, %{"status" => "same"}} = Payload.compare(report, verified)
    refute inspect(verified) =~ "sk-"
    assert {:error, :trusted_public_key_required} = Payload.verify(root)
    assert {:error, :trusted_public_key_required} = Payload.verify(root, public_key: nil)
  end

  test "fails verification when the archive changes", %{root: root} do
    key = Payload.generate_key()
    archive = Path.join(root, "jido-0.1.0-darwin-arm64.tar.gz")
    assert {:ok, _report} = Payload.seal(root, archive: archive, keypair: key)
    File.write!(archive, "tampered")

    assert {:error, {:checksum_mismatch, "jido-0.1.0-darwin-arm64.tar.gz"}} =
             Payload.verify(root, public_key: key.public)
  end

  test "repeated seals produce the same semantic payload", %{root: root} do
    key = Payload.generate_key()
    archive = Path.join(root, "jido-0.1.0-darwin-arm64.tar.gz")
    assert {:ok, first} = Payload.seal(root, archive: archive, keypair: key)
    assert {:ok, second} = Payload.seal(root, archive: archive, keypair: key)
    assert {:ok, %{"allowed_differences" => ["sealed_at"]}} = Payload.compare(first, second)
  end

  test "normalizes missing files, checksum text, signatures, versions, licenses, and comparisons", %{root: root} do
    archive_name = "jido-0.1.0-darwin-arm64.tar.gz"
    archive = Path.join(root, archive_name)

    assert {:error, :enoent} = Payload.checksum(root, archive_name)
    assert {:error, :enoent} = Payload.archive_checksum(root)
    assert {:error, {:missing_release_file, "missing"}} = Payload.checksums(root, ["missing"])
    assert {:error, :archive_missing} = Payload.seal(root, archive: Path.join(root, "missing"))

    key = Payload.generate_key()
    assert {:ok, report} = Payload.seal(root, archive: archive, keypair: key)
    assert {:ok, digest} = Payload.checksum(root, archive_name)
    assert {:ok, ^digest} = Payload.archive_checksum(root)

    assert {:error, {:payload_mismatch, ["version"]}} =
             Payload.compare(report, %{report | "version" => "2.0.0"})

    signature_path = Path.join(root, "payload.sig")
    signature = File.read!(signature_path)
    File.write!(signature_path, "not-base64")
    assert {:error, :payload_signature_invalid} = Payload.verify(root, public_key: key.public)
    File.write!(signature_path, signature)

    payload_path = Path.join(root, "payload.json")
    payload = File.read!(payload_path)
    File.write!(payload_path, Jason.encode!(%{"version" => "2.0.0"}))
    assert {:error, :version_mismatch} = Payload.verify(root, public_key: key.public)
    File.write!(payload_path, payload)

    license_path = Path.join(root, "LICENSE")
    File.write!(license_path, "proprietary")
    assert {:error, :license_mismatch} = Payload.verify(root, public_key: key.public)
    File.write!(license_path, "Apache License Version 2.0")

    checksums_path = Path.join(root, "checksums.txt")
    File.write!(checksums_path, "malformed")
    assert {:error, :checksum_malformed} = Payload.verify(root, public_key: key.public)
    assert {:error, :archive_checksum_missing} = Payload.checksum(root, archive_name)
    assert {:error, :archive_checksum_missing} = Payload.archive_checksum(root)
  end
end
