defmodule Jido.Console.Session.Durable.CatalogTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Continuity
  alias Jido.Console.Session.Durable.Catalog

  test "the catalog covers every authoritative Console record exactly once" do
    assert :ok = Catalog.review()
    assert %{"schema" => "jido.console.durable-catalog"} = Catalog.schema()
    assert {:ok, continuity} = Continuity.schema()

    expected =
      continuity
      |> Continuity.records()
      |> Enum.filter(&(&1["class"] == "authoritative" and String.starts_with?(&1["owner"], "console")))
      |> Enum.map(& &1["name"])
      |> Enum.sort()

    assert Catalog.record_types() == expected
    assert length(expected) == 16

    for type <- expected do
      assert {:ok, %{"required" => required, "fields" => fields}} = Catalog.record_type(type)
      assert required != []
      assert required -- fields == []

      for field <- fields do
        assert {:ok, declared_type} = Catalog.field_type(field)
        assert is_binary(declared_type)
      end
    end

    assert {:error, {:unknown_record_field, "missing"}} = Catalog.field_type("missing")
    assert {:error, {:unknown_durable_limit, "missing"}} = Catalog.limit("missing")
  end

  test "the compatibility matrix separates store, record, and Jidoka versions" do
    matrix = Catalog.compatibility()

    assert matrix["current"] == %{
             "store_format" => 1,
             "record_schema" => 1,
             "jidoka_envelope" => 1
           }

    assert Enum.any?(matrix["rules"], &(&1["result"] == "incompatible_future_store_format"))
    assert Enum.all?(matrix["rules"], &(&1["mutation"] == false))
    assert {:ok, 262_144} = Catalog.limit("console_record_bytes")
    assert {:ok, 134_217_728} = Catalog.limit("jidoka_value_bytes")
    assert {:error, {:unknown_record_type, "missing"}} = Catalog.record_type("missing")
  end

  test "the published canonical fixture conforms to the record codec" do
    fixture_path = Path.join(Path.dirname(Catalog.schema_path()), "conformance-fixtures.v1.json")

    assert {:ok, fixture_bytes} = File.read(fixture_path)
    assert {:ok, fixtures} = Jason.decode(fixture_bytes)
    assert fixtures["schema"] == "jido.console.durable-conformance-fixtures"
    assert fixtures["version"] == 1

    assert {:ok, encoded} =
             Jido.Console.Session.Durable.Record.encode(fixtures["canonical_record"])

    assert {:ok, ^encoded} = Jido.Console.Session.Durable.Record.decode(encoded.bytes)
    assert length(fixtures["negative_cases"]) == 11
  end
end
