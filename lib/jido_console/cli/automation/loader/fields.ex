defmodule Jido.Console.Automation.Loader.Fields do
  @moduledoc false

  @forbidden_execution_keys ~w(
    execution_environment runtime_profile adapter backend command image mount mounts network
    replay fixture fixture_path fixture_json fixture_digest
  )

  @doc false
  @spec version_one(map(), Path.t()) :: :ok | {:error, term()}
  def version_one(document, path) do
    case Map.get(document, "version", 1) do
      1 -> :ok
      version -> {:error, {:unsupported_document_version, path, version, 1}}
    end
  end

  @doc false
  @spec reject_execution_controls(term()) :: :ok | {:error, term()}
  def reject_execution_controls(map) when is_map(map) do
    keys = map |> Map.keys() |> Enum.map(&to_string/1)

    case keys -- (keys -- @forbidden_execution_keys) do
      [] -> :ok
      forbidden -> {:error, {:forbidden_execution_profile_keys, Enum.sort(forbidden)}}
    end
  end

  def reject_execution_controls(_value), do: :ok

  @doc false
  @spec map_value(term(), atom()) :: {:ok, map()} | {:error, term()}
  def map_value(value, _field) when is_map(value), do: {:ok, value}
  def map_value(value, field), do: {:error, {:invalid_map_value, field, value}}

  @doc false
  @spec matrix_value(map(), String.t(), term()) :: term()
  def matrix_value(suite, key, default) do
    suite |> Map.get("matrix", %{}) |> Map.get(key, default)
  end

  @doc false
  @spec run_value(map(), String.t(), term()) :: term()
  def run_value(suite, key, default) do
    suite |> Map.get("run", %{}) |> Map.get(key, default)
  end

  @doc false
  @spec unique_values([map()], atom(), atom()) :: :ok | {:error, term()}
  def unique_values(items, field, kind) do
    duplicate =
      items
      |> Enum.map(&Map.fetch!(&1, field))
      |> Enum.frequencies()
      |> Enum.find_value(fn {value, count} -> if count > 1, do: value end)

    if duplicate, do: {:error, {:duplicate_id, kind, duplicate}}, else: :ok
  end

  @doc false
  @spec resolve_path(Path.t(), Path.t()) :: Path.t()
  def resolve_path(base_dir, path), do: Path.expand(path, base_dir)

  @doc false
  @spec key(String.t()) :: String.t()
  def key(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "item"
      key -> key
    end
  end

  @doc false
  @spec reverse_result({:ok, list()} | {:error, term()}) :: {:ok, list()} | {:error, term()}
  def reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  def reverse_result(error), do: error

  @doc false
  @spec maybe_put(map(), atom(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)
end
