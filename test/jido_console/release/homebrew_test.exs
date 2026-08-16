defmodule Jido.Console.Release.HomebrewTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.{Homebrew, PayloadFixture}

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

    result = Homebrew.lifecycle(payload, prefix, public_key: key.public)
    assert result["status"] == "pass"
    assert Enum.map(result["stages"], & &1["stage"]) == ~w(install first_run update remove)
    first = Enum.find(result["stages"], &(&1["stage"] == "first_run"))
    install = Enum.find(result["stages"], &(&1["stage"] == "install"))
    assert first["compiled"] == false
    assert install["method"] == "homebrew_formula"
    assert install["formula"] == "Formula/jido.rb"
    assert install["cellar"] == "Cellar/jido/0.1.0"
    refute File.exists?(prefix)
    refute inspect(result) =~ "sk-"
  end
end
