defmodule Jido.Console.Session.Durable.MigrationTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Durable.Migration

  defmodule AddFormat do
    @behaviour Migration
    @checksum "sha256:" <> String.duplicate("1", 64)

    @impl true
    def id, do: "add_format_v1"

    @impl true
    def source_version, do: 0

    @impl true
    def target_version, do: 1

    @impl true
    def checksum, do: @checksum

    @impl true
    def transform(value), do: {:ok, Map.put_new(value, "store_format_version", 1)}
  end

  defmodule Nondeterministic do
    @behaviour Migration

    @impl true
    def id, do: "nondeterministic"

    @impl true
    def source_version, do: 0

    @impl true
    def target_version, do: 1

    @impl true
    def checksum, do: "sha256:" <> String.duplicate("2", 64)

    @impl true
    def transform(value), do: {:ok, Map.put(value, "nonce", System.unique_integer([:positive]))}
  end

  defmodule Failing do
    @behaviour Migration
    def id, do: "failing"
    def source_version, do: 0
    def target_version, do: 1
    def checksum, do: "sha256:" <> String.duplicate("3", 64)
    def transform(_value), do: {:error, :fixture_failure}
  end

  defmodule InvalidResult do
    @behaviour Migration
    def id, do: "invalid_result"
    def source_version, do: 0
    def target_version, do: 1
    def checksum, do: "sha256:" <> String.duplicate("4", 64)
    def transform(_value), do: {:ok, :not_a_map}
  end

  defmodule EmptyId do
    @behaviour Migration
    def id, do: ""
    def source_version, do: 0
    def target_version, do: 1
    def checksum, do: "sha256:" <> String.duplicate("5", 64)
    def transform(value), do: {:ok, value}
  end

  defmodule BadChecksum do
    @behaviour Migration
    def id, do: "bad_checksum"
    def source_version, do: 0
    def target_version, do: 1
    def checksum, do: "invalid"
    def transform(value), do: {:ok, value}
  end

  defmodule MissingCallbacks do
    def id, do: "missing_callbacks"
    def source_version, do: 0
  end

  defmodule ExplodingSource do
    def source_version, do: raise("invalid source callback")
  end

  test "ordered migration results are checksum-identified and idempotent" do
    fixture = %{"name" => "fixture"}
    assert :ok = Migration.conform(AddFormat, fixture)

    assert {:ok, result} = Migration.run(fixture, 0, 1, [AddFormat])
    assert result.status == :migrated
    assert result.value == %{"name" => "fixture", "store_format_version" => 1}

    assert result.ledger == [
             %{
               id: "add_format_v1",
               source_version: 0,
               target_version: 1,
               checksum: AddFormat.checksum(),
               status: :applied
             }
           ]

    assert {:ok, current} = Migration.run(result.value, 1, 1, [AddFormat])
    assert current.status == :current
    assert current.value == result.value
    assert current.ledger == []
  end

  test "future, missing, and nondeterministic migrations fail without a replacement value" do
    fixture = %{"name" => "fixture"}

    assert {:error, {:incompatible_future_store_format, 2, 1}} = Migration.run(fixture, 2, 1, [])
    assert {:error, {:missing_migration_step, 0, 1}} = Migration.run(fixture, 0, 1, [])

    assert {:error, {:nondeterministic_or_non_idempotent_migration, Nondeterministic}} =
             Migration.conform(Nondeterministic, fixture)
  end

  test "invalid migration steps and results return typed errors" do
    fixture = %{"name" => "fixture"}

    assert {:error, :invalid_migration_input} = Migration.run([], 0, 1, [])
    assert {:error, :fixture_failure} = Migration.conform(Failing, fixture)

    assert {:error, {:migration_failed, "failing", :fixture_failure}} =
             Migration.run(fixture, 0, 1, [Failing])

    assert {:error, {:invalid_migration_result, InvalidResult}} =
             Migration.run(fixture, 0, 1, [InvalidResult])

    assert {:error, {:invalid_migration_step, MissingCallbacks}} =
             Migration.run(fixture, 0, 1, [MissingCallbacks])

    assert {:error, {:invalid_migration_id, EmptyId}} =
             Migration.run(fixture, 0, 1, [EmptyId])

    assert {:error, {:migration_checksum_invalid, BadChecksum}} =
             Migration.run(fixture, 0, 1, [BadChecksum])

    assert {:error, {:missing_migration_step, 0, 1}} =
             Migration.run(fixture, 0, 1, [ExplodingSource])

    assert {:error, {:invalid_migration_step, __MODULE__, %UndefinedFunctionError{}}} =
             Migration.conform(__MODULE__, fixture)
  end
end
