defmodule Jido.Console.Release.ContractTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.Contract

  @version "1.2.3"
  @target "darwin-arm64"

  test "defines stable macOS ARM64 and later target names" do
    assert Contract.root_name(@version, @target) == "jido-1.2.3-darwin-arm64"
    assert Contract.archive_name(@version, @target) == "jido-1.2.3-darwin-arm64.tar.gz"
    assert Contract.archive_name(@version, "windows-x64") == "jido-1.2.3-windows-x64.zip"
    assert {:error, {:unsupported_target, "other"}} = Contract.target_spec("other")
  end

  test "builds strict metadata and future Homebrew inputs" do
    metadata = metadata()

    assert :ok = Contract.validate_metadata(metadata)

    assert Contract.homebrew_inputs(metadata, String.duplicate("a", 64)) == %{
             "artifact" => "jido-1.2.3-darwin-arm64.tar.gz",
             "executable" => "bin/jido",
             "sha256" => String.duplicate("a", 64),
             "target" => "darwin-arm64",
             "version" => "1.2.3"
           }
  end

  test "rejects inconsistent target metadata" do
    metadata = Map.put(metadata(), "artifact", "wrong.tar.gz")

    assert {:error, {:invalid_field, "artifact", "wrong.tar.gz", _expected}} =
             Contract.validate_metadata(metadata)
  end

  test "accepts the complete local package evidence shape" do
    complete =
      metadata()
      |> Map.put("archive_checksum", "checksums.txt")
      |> Map.put("native_files", ["libexec/lib/native.so"])
      |> Map.put("components", [
        %{
          "kind" => "dependency",
          "license_file" => "deps/sample/LICENSE",
          "licenses" => ["MIT"],
          "name" => "sample",
          "native_files" => [],
          "source" => "hex://hexpm/sample@1.0.0",
          "version" => "1.0.0"
        }
      ])
      |> Map.update!("build", fn build ->
        Map.merge(build, %{
          "build_time_utc" => "2023-11-14T22:13:20Z",
          "reproducible" => true,
          "toolchain_file" => ".tool-versions"
        })
      end)

    assert :ok = Contract.validate_metadata(complete)
  end

  test "validates a relocatable package layout and launcher entry" do
    root = package_fixture()

    assert :ok = Contract.validate_layout(root, metadata())

    moved = Path.join(Path.dirname(root), "space and ünicode/jido-1.2.3-darwin-arm64")
    File.mkdir_p!(Path.dirname(moved))
    File.rename!(root, moved)

    assert :ok = Contract.validate_layout(moved, metadata())
  end

  test "rejects a launcher that exposes release eval" do
    root = package_fixture()
    launcher = Path.join(root, "bin/jido")
    File.write!(launcher, "#!/bin/sh\nexec private eval expression -extra \"$@\"\n# libexec\n")
    File.chmod!(launcher, 0o755)

    assert {:error, :launcher_uses_release_eval} = Contract.validate_layout(root, metadata())
  end

  test "rejects malformed metadata, package entries, and launcher variants" do
    assert Contract.schema_version() == 1
    assert_raise ArgumentError, fn -> Contract.root_name("invalid", @target) end
    assert_raise ArgumentError, fn -> apply(Contract, :root_name, [123, @target]) end
    assert_raise ArgumentError, fn -> Contract.archive_name(@version, "other") end
    assert_raise ArgumentError, fn -> Contract.homebrew_inputs(metadata(), "short") end
    assert {:error, {:metadata_not_a_map, :invalid}} = Contract.validate_metadata(:invalid)

    assert {:error, :invalid_file_inventory} =
             metadata()
             |> Map.put("files", [
               %{"path" => "../secret", "sha256" => String.duplicate("a", 64), "size" => 1}
             ])
             |> Contract.validate_metadata()

    assert {:error, _reason} =
             metadata()
             |> Map.put("files", :invalid)
             |> Contract.validate_metadata()

    assert {:error, {:invalid_field, "root", "wrong", _expected}} =
             metadata()
             |> Map.put("root", "wrong")
             |> Contract.validate_metadata()

    root = package_fixture()

    assert {:error, {:invalid_root_name, "wrong", _expected}} =
             Contract.validate_layout(Path.join(Path.dirname(root), "wrong"), metadata())

    File.rm!(Path.join(root, "LICENSE"))
    assert {:error, {:missing_package_path, "LICENSE"}} = Contract.validate_layout(root, metadata())
    File.write!(Path.join(root, "LICENSE"), "license")

    launcher = Path.join(root, "bin/jido")
    File.chmod!(launcher, 0o644)
    assert {:error, {:invalid_executable, _stat}} = Contract.validate_layout(root, metadata())
    File.rm!(launcher)
    assert {:error, {:missing_package_path, "bin/jido"}} = Contract.validate_layout(root, metadata())

    variants = [
      {"exit 0\n", :launcher_has_no_portable_shell_header},
      {"#!/bin/sh\nunset BINDIR ROOTDIR\nexec private -extra \"$@\"\n", :launcher_does_not_use_private_runtime},
      {"#!/bin/sh\nunset BINDIR ROOTDIR\nexec libexec/private \"$@\"\n", :launcher_does_not_preserve_arguments},
      {"#!/bin/sh\nexec libexec/private -extra \"$@\"\n", :launcher_does_not_isolate_parent_beam}
    ]

    for {body, expected} <- variants do
      File.write!(launcher, body)
      File.chmod!(launcher, 0o755)
      assert {:error, ^expected} = Contract.validate_layout(root, metadata())
    end
  end

  defp metadata do
    Contract.metadata!(
      version: @version,
      target: @target,
      identity: %{elixir: "1.20.2", otp: "28", jidoka: "0.9.1"},
      jidoka_ref: String.duplicate("b", 40),
      source: %{commit: String.duplicate("a", 40), dirty: false},
      source_date_epoch: 1_700_000_000
    )
  end

  defp package_fixture do
    root = Path.join(System.tmp_dir!(), "jido-contract-#{System.unique_integer([:positive])}")
    root = Path.join(root, Contract.root_name(@version, @target))
    on_exit(fn -> File.rm_rf!(Path.dirname(root)) end)

    File.mkdir_p!(Path.join(root, "bin"))
    File.mkdir_p!(Path.join(root, "libexec"))
    File.write!(Path.join(root, "LICENSE"), "license")
    File.write!(Path.join(root, "THIRD_PARTY_NOTICES"), "notices")
    File.write!(Path.join(root, "release.json"), Jason.encode!(metadata()))

    launcher = Path.join(root, "bin/jido")

    File.write!(
      launcher,
      "#!/bin/sh\nunset BINDIR ROOTDIR\nROOT=relative\nexec \"$ROOT/libexec/private\" -extra \"$@\"\n"
    )

    File.chmod!(launcher, 0o755)
    root
  end
end
