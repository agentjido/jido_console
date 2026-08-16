defmodule Jido.Console.DocumentTest do
  use ExUnit.Case, async: true

  alias Jido.Console.{Digest, Document}

  setup do
    root = Path.join(System.tmp_dir!(), "jido-document-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "reads bounded documents and computes streaming digests", %{root: root} do
    path = Path.join(root, "value.json")
    contents = Jason.encode!(%{"value" => String.duplicate("x", 70_000)})
    File.write!(path, contents)

    assert Digest.hex("value") == :crypto.hash(:sha256, "value") |> Base.encode16(case: :lower)
    assert Digest.portable("value") == "sha256:" <> Digest.hex("value")
    assert {:ok, digest} = Digest.file(path)
    assert digest == Digest.portable(contents)

    assert {:ok, %{"value" => value}, ^contents} = Document.decode_file(path)
    assert byte_size(value) == 70_000
    assert {:error, {:not_regular_file, :directory}} = Digest.file(root)
    assert {:error, :enoent} = Digest.file(path <> ".missing")
  end

  test "reports every bounded file and schema failure", %{root: root} do
    regular = Path.join(root, "regular.yaml")
    File.write!(regular, "value: yes\n")

    assert {:error, {:file_read_failed, ^regular, {:invalid_file_size_limit, 0}}} =
             Document.read_text(regular, max_file_bytes: 0)

    assert {:error, {:file_read_failed, ^regular, {:file_too_large, ^regular, 11, 2}}} =
             Document.read_text(regular, max_file_bytes: 2)

    assert {:error, {:file_read_failed, ^root, {:not_regular, :directory}}} =
             Document.read_text(root)

    missing = Path.join(root, "missing")
    assert {:error, {:file_read_failed, ^missing, :enoent}} = Document.read_text(missing)

    invalid_utf8 = Path.join(root, "invalid.txt")
    File.write!(invalid_utf8, <<255>>)
    assert {:error, {:file_read_failed, ^invalid_utf8, :invalid_utf8}} = Document.read_text(invalid_utf8)

    assert {:error, {:decode_failed, "bad.json", %Jason.DecodeError{}}} = Document.decode("bad.json", "{")
    assert {:ok, %{"value" => true}} = Document.decode("value.yaml", "value: true\n")

    schema = Zoi.map(%{"name" => Document.non_empty_string()}, unrecognized_keys: :error)
    assert {:ok, %{"name" => "valid"}} = Document.validate(schema, %{"name" => "valid"}, :test)

    assert {:error, {:document_schema_invalid, :test, _errors}} =
             Document.validate(schema, %{"name" => " "}, :test)

    assert {:ok, _value} = Zoi.parse(Document.hex40(), String.duplicate("a", 40))
    assert {:ok, _value} = Zoi.parse(Document.hex64(), String.duplicate("a", 64))
    assert {:ok, _value} = Zoi.parse(Document.sha256_digest(), "sha256:" <> String.duplicate("a", 64))
    assert {:ok, _value} = Zoi.parse(Document.version_string(), "1.2.3-rc.1")
  end
end
