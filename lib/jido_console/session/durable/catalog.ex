defmodule Jido.Console.Session.Durable.Catalog do
  @moduledoc "Versioned catalog for durable Console records and compatibility rules."

  @catalog_path Path.expand("../../../../priv/session/durable/schema-catalog.v1.json", __DIR__)
  @compatibility_path Path.expand("../../../../priv/session/durable/compatibility-matrix.v1.json", __DIR__)
  @external_resource @catalog_path
  @external_resource @compatibility_path
  @catalog @catalog_path |> File.read!() |> Jason.decode!()
  @compatibility @compatibility_path |> File.read!() |> Jason.decode!()

  @type catalog :: map()

  @doc "Returns the embedded durable schema catalog."
  @spec schema() :: catalog()
  def schema, do: @catalog

  @doc "Returns the embedded durable compatibility matrix."
  @spec compatibility() :: map()
  def compatibility, do: @compatibility

  @doc "Returns the installed durable schema path."
  @spec schema_path() :: Path.t()
  def schema_path, do: priv_path("schema-catalog.v1.json")

  @doc "Returns all current authoritative Console record type names."
  @spec record_types() :: [String.t()]
  def record_types do
    @catalog["record_types"] |> Map.keys() |> Enum.sort()
  end

  @doc "Returns one strict record declaration."
  @spec record_type(String.t()) :: {:ok, map()} | {:error, term()}
  def record_type(name) when is_binary(name) do
    case get_in(@catalog, ["record_types", name]) do
      declaration when is_map(declaration) -> {:ok, declaration}
      _other -> {:error, {:unknown_record_type, name}}
    end
  end

  @doc "Returns the declared type for one record payload field."
  @spec field_type(String.t()) :: {:ok, String.t()} | {:error, term()}
  def field_type(name) when is_binary(name) do
    case get_in(@catalog, ["field_types", name]) do
      type when is_binary(type) -> {:ok, type}
      _other -> {:error, {:unknown_record_field, name}}
    end
  end

  @doc "Returns one positive byte or count limit."
  @spec limit(String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def limit(name) when is_binary(name) do
    case get_in(@catalog, ["limits", name]) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {:unknown_durable_limit, name}}
    end
  end

  @doc "Checks the catalog identity, record inventory, and compatibility identity."
  @spec review() :: :ok | {:error, [term()]}
  def review do
    declarations = @catalog["record_types"] || %{}
    declared_fields = declarations |> Enum.flat_map(fn {_name, value} -> value["fields"] || [] end) |> Enum.uniq()
    typed_fields = @catalog["field_types"] |> Map.keys()

    defects =
      []
      |> maybe_add(@catalog["schema"] != "jido.console.durable-catalog", :invalid_durable_catalog)
      |> maybe_add(@catalog["version"] != 1, :invalid_durable_catalog_version)
      |> maybe_add(@catalog["store_format_version"] != 1, :invalid_store_format_version)
      |> maybe_add(map_size(declarations) != 16, :invalid_authoritative_record_inventory)
      |> maybe_add(Enum.any?(declarations, &invalid_declaration?/1), :invalid_record_declaration)
      |> maybe_add(Enum.sort(declared_fields) != Enum.sort(typed_fields), :incomplete_record_field_types)
      |> maybe_add(@compatibility["schema"] != "jido.console.durable-compatibility", :invalid_compatibility_matrix)

    if defects == [], do: :ok, else: {:error, Enum.reverse(defects)}
  end

  defp invalid_declaration?({_name, %{"required" => required, "fields" => fields}}) do
    not is_list(required) or not is_list(fields) or required == [] or fields == [] or required -- fields != []
  end

  defp invalid_declaration?(_declaration), do: true

  defp priv_path(name) do
    :jido_console
    |> :code.priv_dir()
    |> List.to_string()
    |> Path.join("session/durable/#{name}")
  end

  defp maybe_add(defects, true, defect), do: [defect | defects]
  defp maybe_add(defects, false, _defect), do: defects
end
