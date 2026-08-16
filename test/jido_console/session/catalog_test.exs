defmodule Jido.Console.Session.CatalogTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Catalog

  test "registers command and client declarations from one contract" do
    catalog = Catalog.new()

    assert {:ok, catalog} = Catalog.put_command(catalog, command())
    assert {:ok, catalog} = Catalog.put_client(catalog, client())
    assert {:ok, command} = Catalog.fetch_command(catalog, "help")
    assert {:ok, client} = Catalog.fetch_client(catalog, "tui")
    assert command["help"] =~ "help"
    assert client["capabilities"] == ["input", "output", "snapshot", "control"]
    refute Map.has_key?(command, :ansi)
    assert Catalog.commands(catalog) == [command]
  end

  test "rejects duplicate, conflicting, and incomplete declarations" do
    {:ok, catalog} = Catalog.put_command(Catalog.new(), command())
    assert {:error, :duplicate_declaration} = Catalog.put_command(catalog, command())

    assert {:error, :conflicting_declaration} =
             Catalog.put_command(catalog, %{command() | "id" => "cmd_other"})

    assert {:error, {:incomplete_declaration, missing}} = Catalog.put_command(Catalog.new(), %{"name" => "x"})
    assert "id" in missing
  end

  test "unknown fields stay data and cannot grant authority" do
    assert {:ok, catalog} = Catalog.put_command(Catalog.new(), Map.put(command(), "note", "extra"))
    assert {:ok, command} = Catalog.fetch_command(catalog, "cmd_help")
    assert command["unknown"]["note"] == "extra"

    assert {:error, {:unknown_authority_field, ["permission"]}} =
             Catalog.put_command(Catalog.new(), Map.put(command(), "permission", "all"))
  end

  test "bounds invalid identities and unknown data for both declaration families" do
    assert {:error, :invalid_declaration_identity} =
             Catalog.put_command(Catalog.new(), %{command() | "id" => 1})

    assert {:error, :unknown_data_overflow} =
             Catalog.put_command(Catalog.new(), Map.put(command(), "large", String.duplicate("x", 5_000)))

    assert {:error, :unknown_data_overflow} =
             Catalog.put_command(Catalog.new(), Map.put(command(), "callback", fn -> :ok end))

    assert {:ok, catalog} = Catalog.put_client(Catalog.new(), client())
    assert {:ok, descriptor} = Catalog.fetch_client(catalog, "cli_tui")
    assert Catalog.clients(catalog) == [descriptor]
    assert {:error, :not_found} = Catalog.fetch_command(catalog, "missing")
    assert {:error, :duplicate_declaration} = Catalog.put_client(catalog, client())
    assert {:error, :conflicting_declaration} = Catalog.put_client(catalog, %{client() | "version" => "2"})
  end

  defp command do
    %{
      "id" => "cmd_help",
      "version" => "1",
      "name" => "help",
      "help" => "Show help",
      "input_schema" => %{},
      "output_schema" => %{},
      "permissions" => [],
      "provenance" => %{"source" => "builtin"}
    }
  end

  defp client do
    %{
      "id" => "cli_tui",
      "version" => "1",
      "name" => "tui",
      "capabilities" => ["input", "output", "snapshot", "control"],
      "provenance" => %{"source" => "builtin"}
    }
  end
end
