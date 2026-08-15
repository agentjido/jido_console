defmodule Jido.Console.Release.NpmTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.{Channel, Npm, Payload}

  setup do
    root = Path.join(System.tmp_dir!(), "jido-npm-#{System.unique_integer([:positive])}")
    payload = Path.join(root, "payload")
    File.mkdir_p!(payload)
    File.write!(Path.join(payload, "jido-0.1.0-darwin-arm64.tar.gz"), "payload-bytes")
    File.write!(Path.join(payload, "LICENSE"), "Apache License Version 2.0")

    File.write!(
      Path.join(payload, "release.json"),
      Jason.encode!(%{"version" => "0.1.0", "license" => "Apache-2.0"}) <> "\n"
    )

    File.write!(Path.join(payload, "sbom.json"), "{}\n")
    File.write!(Path.join(payload, "provenance.json"), "{}\n")
    key = Payload.generate_key()
    assert {:ok, _} = Payload.seal(payload, archive: Path.join(payload, "jido-0.1.0-darwin-arm64.tar.gz"), keypair: key)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, payload: payload, key: key}
  end

  test "entry package selects the exact darwin-arm64 target", %{payload: payload, root: root, key: key} do
    assert {:ok, packages} = Npm.packages(payload)
    assert packages["entry"]["name"] == "@agentjido/jido-console"
    assert packages["target"]["name"] == "@agentjido/jido-console-darwin-arm64"
    assert packages["entry"]["optionalDependencies"][Npm.target_name()] == "0.1.0"
    assert {:ok, target} = Npm.resolve(packages, "darwin", "arm64")
    assert target == Npm.target_name()
    assert {:error, {:unsupported_npm_target, "linux", "x64"}} = Npm.resolve(packages, "linux", "x64")
    assert packages["entry"]["scripts"] == %{}
    assert packages["target"]["scripts"] == %{}

    Enum.each([:global, :local, :exec, :npx], fn flow ->
      prefix = Path.join(root, Atom.to_string(flow))
      assert {:ok, install} = Npm.install(payload, prefix, flow, public_key: key.public)
      assert {:ok, first} = Channel.first_run(install)
      assert first["compiled"] == false
      assert {:ok, _} = Channel.remove(install)
    end)
  end
end
