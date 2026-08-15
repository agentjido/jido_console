defmodule Jido.Console.Session.Catalog do
  @moduledoc """
  Renderer-neutral registry for commands and client capability descriptors.

  One declaration owns name, help, schemas, permissions, provenance, and
  client capabilities. Duplicate or conflicting declarations fail before
  registration completes. Unknown bounded fields remain data and cannot grant
  authority.
  """

  @type t :: %{commands: %{String.t() => map()}, clients: %{String.t() => map()}}

  @required_command ~w(id version name help input_schema output_schema permissions provenance)
  @required_client ~w(id version name capabilities provenance)
  @authority_fields ~w(permission approval capability principal scope)
  @max_unknown_bytes 4_096

  @doc "Returns an empty catalog."
  @spec new() :: t()
  def new, do: %{commands: %{}, clients: %{}}

  @doc "Registers one command declaration."
  @spec put_command(t(), map()) :: {:ok, t()} | {:error, term()}
  def put_command(catalog, declaration) when is_map(declaration) do
    with {:ok, declaration} <- normalize(declaration, @required_command),
         :ok <- reject_conflict(catalog.commands, declaration) do
      {:ok, %{catalog | commands: Map.put(catalog.commands, declaration["id"], declaration)}}
    end
  end

  @doc "Registers one client descriptor."
  @spec put_client(t(), map()) :: {:ok, t()} | {:error, term()}
  def put_client(catalog, declaration) when is_map(declaration) do
    with {:ok, declaration} <- normalize(declaration, @required_client),
         :ok <- reject_conflict(catalog.clients, declaration) do
      {:ok, %{catalog | clients: Map.put(catalog.clients, declaration["id"], declaration)}}
    end
  end

  @doc "Looks up a command by identity or name."
  @spec fetch_command(t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def fetch_command(catalog, id_or_name) do
    fetch_entry(catalog.commands, id_or_name)
  end

  @doc "Looks up a client descriptor by identity or name."
  @spec fetch_client(t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def fetch_client(catalog, id_or_name) do
    fetch_entry(catalog.clients, id_or_name)
  end

  @doc "Returns renderer-neutral command declarations."
  @spec commands(t()) :: [map()]
  def commands(catalog), do: catalog.commands |> Map.values() |> Enum.sort_by(& &1["name"])

  @doc "Returns renderer-neutral client descriptors."
  @spec clients(t()) :: [map()]
  def clients(catalog), do: catalog.clients |> Map.values() |> Enum.sort_by(& &1["name"])

  defp normalize(declaration, required) do
    declaration = stringify_keys(declaration)
    missing = Enum.reject(required, &present?(declaration[&1]))

    cond do
      missing != [] ->
        {:error, {:incomplete_declaration, missing}}

      not is_binary(declaration["id"]) or not is_binary(declaration["version"]) ->
        {:error, :invalid_declaration_identity}

      true ->
        bound_unknown(declaration)
    end
  end

  defp reject_conflict(existing, declaration) do
    case Map.get(existing, declaration["id"]) do
      nil ->
        name_conflict =
          Enum.find(existing, fn {_id, current} ->
            current["name"] == declaration["name"] and current["id"] != declaration["id"]
          end)

        if name_conflict, do: {:error, :conflicting_declaration}, else: :ok

      ^declaration ->
        {:error, :duplicate_declaration}

      _other ->
        {:error, :conflicting_declaration}
    end
  end

  defp fetch_entry(entries, id_or_name) do
    case Map.get(entries, id_or_name) do
      nil ->
        Enum.find_value(entries, {:error, :not_found}, fn {_id, declaration} ->
          if declaration["name"] == id_or_name, do: {:ok, declaration}
        end)

      declaration ->
        {:ok, declaration}
    end
  end

  defp bound_unknown(declaration) do
    known = MapSet.new(@required_command ++ @required_client ++ ["unknown"])
    unknown = Map.drop(declaration, MapSet.to_list(known))

    leaked = Enum.filter(Map.keys(unknown), &(&1 in @authority_fields))

    cond do
      leaked != [] ->
        {:error, {:unknown_authority_field, leaked}}

      encoded_size(unknown) > @max_unknown_bytes ->
        {:error, :unknown_data_overflow}

      unknown == %{} ->
        {:ok, declaration}

      true ->
        {:ok, declaration |> Map.drop(Map.keys(unknown)) |> Map.put("unknown", unknown)}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp present?(value) when value in [nil, ""], do: false
  defp present?(_value), do: true

  defp encoded_size(value) do
    case Jason.encode(value) do
      {:ok, json} -> byte_size(json)
      {:error, _reason} -> @max_unknown_bytes + 1
    end
  end
end
