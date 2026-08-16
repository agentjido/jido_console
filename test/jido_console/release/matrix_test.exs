defmodule Jido.Console.Release.MatrixTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.{Channel, Matrix, PayloadFixture}

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
    assert Enum.all?(report["supported_cells"], &(length(&1["stages"]) == 4))
    assert Enum.all?(report["supported_cells"], &Map.has_key?(&1["payload_identity"], "checksum"))
    assert Enum.all?(report["supported_cells"], &Map.has_key?(&1["payload_identity"], "provenance"))
    assert Enum.all?(report["supported_cells"], &Map.has_key?(&1["payload_identity"], "version"))
    assert Enum.all?(report["supported_cells"], &Map.has_key?(&1["payload_identity"], "license"))
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
    assert Enum.all?(report["supported_cells"], &(&1["status"] == "fail"))
    assert Enum.all?(report["supported_cells"], &(hd(&1["stages"])["stage"] == "install"))
  end

  test "a Homebrew failure fails only its cell", %{root: root, payload: payload, key: key} do
    assert {:error, {:matrix_failed, report}} =
             Matrix.verify(payload,
               public_key: key.public,
               archive: "missing.tar.gz",
               root: Path.join(root, "isolated-failure")
             )

    statuses = Map.new(report["supported_cells"], &{&1["channel"], &1["status"]})
    assert statuses == %{"archive" => "pass", "homebrew" => "fail", "npm" => "pass"}

    homebrew = Enum.find(report["supported_cells"], &(&1["channel"] == "homebrew"))
    assert Enum.map(homebrew["stages"], & &1["status"]) == ["fail", "not_run", "not_run", "not_run"]
    assert report["comparison"]["status"] == "pass"
  end

  test "reports the fields that differ between valid channel identities", %{root: root, payload: payload, key: key} do
    assert {:ok, report} =
             Matrix.verify(payload, public_key: key.public, root: Path.join(root, "identity-mismatch"))

    results =
      Enum.map(report["supported_cells"], fn
        %{"channel" => "homebrew"} = result -> change_identity_version(result, "0.2.0")
        result -> result
      end)

    assert Enum.all?(results, fn result ->
             channel = String.to_existing_atom(result["channel"])
             Channel.validate_result(result, channel) == :ok
           end)

    assert Matrix.compare(results) == %{
             "status" => "fail",
             "reason" => "payload identity mismatch: version"
           }
  end

  test "reports an unavailable identity for an empty comparison" do
    assert Enum.map(Matrix.cells(), & &1.channel) == [:archive, :homebrew, :npm]

    assert Matrix.compare([]) == %{
             "status" => "fail",
             "reason" => "payload identity unavailable"
           }
  end

  defp change_identity_version(result, version) do
    result
    |> put_in(["payload_identity", "version"], version)
    |> Map.update!("stages", fn stages ->
      Enum.map(stages, fn stage ->
        if Map.has_key?(stage, "version"), do: Map.put(stage, "version", version), else: stage
      end)
    end)
  end
end
