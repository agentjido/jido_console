defmodule Jido.Console.Release.MatrixTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.{Matrix, PayloadFixture}

  setup do
    root = Path.join(System.tmp_dir!(), "jido-matrix-#{System.unique_integer([:positive])}")
    payload = Path.join(root, "payload")
    File.mkdir_p!(payload)
    fixture = PayloadFixture.create(payload)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, payload: payload, key: fixture.key}
  end

  test "passes the darwin-arm64 archive, Homebrew, and npm cells", %{root: root, payload: payload, key: key} do
    assert {:ok, report} = Matrix.verify(payload, public_key: key.public, root: Path.join(root, "matrix"))
    assert report["decision"] == "pass"
    assert length(report["supported_cells"]) == 3
    assert Enum.all?(report["supported_cells"], &(&1["status"] == "pass"))
    assert report["comparison"]["status"] == "pass"
    assert "linux" in report["untested"]
    refute Enum.any?(report["untested"], &(&1 == "supported"))
    refute inspect(report) =~ "sk-"
  end

  test "fails the matrix when a payload checksum would mismatch", %{root: root, payload: payload, key: key} do
    File.write!(Path.join(payload, "jido-0.1.0-darwin-arm64.tar.gz"), "tampered")

    assert {:error, {:matrix_failed, report}} =
             Matrix.verify(payload, public_key: key.public, root: Path.join(root, "fail"))

    assert report["decision"] == "fail"
    assert Enum.any?(report["supported_cells"], &(&1["status"] == "fail"))
    assert Enum.any?(report["supported_cells"], &(&1["stage"] == "install"))
  end
end
