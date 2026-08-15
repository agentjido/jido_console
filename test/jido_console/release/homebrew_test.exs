defmodule Jido.Console.Release.HomebrewTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.{Channel, Homebrew, PayloadFixture}

  setup do
    root = Path.join(System.tmp_dir!(), "jido-brew-#{System.unique_integer([:positive])}")
    payload = Path.join(root, "payload")
    prefix = Path.join(root, "prefix")
    File.mkdir_p!(payload)
    fixture = PayloadFixture.create(payload)
    on_exit(fn -> File.rm_rf!(root) end)
    %{payload: payload, prefix: prefix, key: fixture.key}
  end

  test "formula pins the payload checksum and does not compile", %{payload: payload, prefix: prefix, key: key} do
    assert {:ok, formula} = Homebrew.formula(payload)
    assert formula =~ "sha256"
    assert formula =~ "version \"0.1.0\""
    assert formula =~ "revision #{Homebrew.revision()}"
    refute formula =~ "mix"
    refute formula =~ "erl"

    assert {:ok, install} = Homebrew.install(payload, prefix, public_key: key.public)
    assert {:ok, first} = Channel.first_run(install)
    assert first["compiled"] == false
    assert {:ok, _} = Channel.remove(install)
    refute inspect(Channel.evidence(:homebrew, [first])) =~ "sk-"
  end
end
