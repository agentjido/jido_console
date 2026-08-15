defmodule Jido.Console.Release.GoldenTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.{Golden, Payload}

  setup do
    root = Path.join(System.tmp_dir!(), "jido-golden-#{System.unique_integer([:positive])}")
    payload = Path.join(root, "payload")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(payload)
    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "lib/value.ex"), "def answer, do: 41\n")
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
    %{root: root, payload: payload, workspace: workspace, key: key}
  end

  test "proves the restricted golden workflow on the installed payload", %{
    root: root,
    payload: payload,
    workspace: workspace,
    key: key
  } do
    assert {:ok, report} =
             Golden.prove(payload, workspace, public_key: key.public, prefix: Path.join(root, "install"))

    assert report["status"] == "passed"
    assert report["profile"] == "coding.restricted"
    assert report["model"] == "openai:gpt-4.1-mini"
    assert report["artifact"]["digest"] != nil
    names = Enum.map(report["steps"], & &1["name"])
    assert Enum.sort(names) == Enum.sort(~w(discover read search edit command test approve reject cancel revert))
    assert Enum.all?(report["steps"], &(&1["status"] == "pass"))
    assert File.read!(Path.join(workspace, "lib/value.ex")) == "def answer, do: 41\n"
    refute inspect(report) =~ "sk-"
  end
end
