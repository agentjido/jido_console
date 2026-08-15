defmodule Jido.Console.Release.NpmTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.{Channel, Npm, PayloadFixture}

  setup do
    root = Path.join(System.tmp_dir!(), "jido-npm-#{System.unique_integer([:positive])}")
    payload = Path.join(root, "payload")
    File.mkdir_p!(payload)
    fixture = PayloadFixture.create(payload)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, payload: payload, key: fixture.key}
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
