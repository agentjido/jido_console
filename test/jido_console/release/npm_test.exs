defmodule Jido.Console.Release.NpmTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.{Npm, PayloadFixture}

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
      result = Npm.lifecycle(payload, prefix, npm_flow: flow, public_key: key.public)
      assert result["status"] == "pass"
      assert Enum.map(result["stages"], & &1["stage"]) == ~w(install first_run update remove)
      first = Enum.find(result["stages"], &(&1["stage"] == "first_run"))
      install = Enum.find(result["stages"], &(&1["stage"] == "install"))
      assert first["compiled"] == false
      assert first["flow"] == Atom.to_string(flow)
      assert install["method"] == "npm_package"
      assert install["entry_package"] == Npm.entry_name()
      assert install["target_package"] == Npm.target_name()
      assert install["entry_path"] == "node_modules/@agentjido/jido-console"
      assert install["target_path"] == "node_modules/@agentjido/jido-console-darwin-arm64"
      assert install["executable"] == "bin/jido"
      refute File.exists?(prefix)
    end)
  end
end
