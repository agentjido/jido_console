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
  @spec required_map(map(), String.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def required_map(map, key, path) do
    case Map.get(map, key) do
      value when is_map(value) -> {:ok, value}
      value -> {:error, {:invalid_required_map, path, key, value}}
    end
  end

  @doc false
  @spec required_id(map(), String.t(), Path.t()) :: {:ok, String.t()} | {:error, term()}
  def required_id(map, key, path) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_required_id, path, key, value}}
    end
  end

  @doc false
  @spec required_string(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_required_string, key, value}}
    end
  end

  @doc false
  @spec optional_id(term(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def optional_id(nil, default), do: {:ok, default}
  def optional_id(value, _default) when is_binary(value) and value != "", do: {:ok, value}
  def optional_id(value, _default), do: {:error, {:invalid_id, value}}

  @doc false
  @spec optional_string(term()) :: {:ok, String.t() | nil} | {:error, term()}
  def optional_string(nil), do: {:ok, nil}
  def optional_string(value) when is_binary(value), do: {:ok, value}
  def optional_string(value), do: {:error, {:invalid_string, value}}

  @doc false
  @spec optional_profile(term()) :: {:ok, String.t() | nil} | {:error, term()}
  def optional_profile(nil), do: {:ok, nil}
  def optional_profile(value) when is_binary(value) and value != "", do: {:ok, value}
  def optional_profile(value), do: {:error, {:invalid_execution_profile, value}}

  @doc false
  @spec optional_section(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def optional_section(map, key) do
    case Map.get(map, key, %{}) do
      value when is_map(value) -> {:ok, value}
      value -> {:error, {:invalid_optional_map, key, value}}
    end
  end

  @doc false
  @spec reject_execution_controls(map()) :: :ok | {:error, term()}
  def reject_execution_controls(map) when is_map(map) do
    keys = map |> Map.keys() |> Enum.map(&to_string/1)

    case keys -- (keys -- @forbidden_execution_keys) do
      [] -> :ok
      forbidden -> {:error, {:forbidden_execution_profile_keys, Enum.sort(forbidden)}}
    end
  end

  @doc false
  @spec optional_map(term()) :: {:ok, map() | nil} | {:error, term()}
  def optional_map(nil), do: {:ok, nil}
  def optional_map(value) when is_map(value), do: {:ok, value}
  def optional_map(value), do: {:error, {:invalid_map, value}}

  @doc false
  @spec optional_output(term(), Path.t()) :: {:ok, Path.t() | nil} | {:error, term()}
  def optional_output(nil, _base_dir), do: {:ok, nil}

  def optional_output(value, base_dir) when is_binary(value) and value != "",
    do: {:ok, resolve_path(base_dir, value)}

  def optional_output(value, _base_dir), do: {:error, {:invalid_output_directory, value}}

  @doc false
  @spec string_or_list(term(), atom()) :: {:ok, String.t() | [String.t()] | nil} | {:error, term()}
  def string_or_list(nil, _field), do: {:ok, nil}
  def string_or_list(value, _field) when is_binary(value), do: {:ok, value}

  def string_or_list(values, _field) when is_list(values) and values != [] do
    if Enum.all?(values, &is_binary/1),
      do: {:ok, values},
      else: {:error, {:invalid_string_list, values}}
  end

  def string_or_list(value, field), do: {:error, {:invalid_assertion, field, value}}

  @doc false
  @spec string_list(term()) :: [String.t()]
  def string_list(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  def string_list(_values), do: []

  @doc false
  @spec positive_integer(term(), atom()) :: {:ok, pos_integer()} | {:error, term()}
  def positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}
  def positive_integer(value, field), do: {:error, {:invalid_positive_integer, field, value}}

  @doc false
  @spec map_value(term(), atom()) :: {:ok, map()} | {:error, term()}
  def map_value(value, _field) when is_map(value), do: {:ok, value}
  def map_value(value, field), do: {:error, {:invalid_map_value, field, value}}

  @doc false
  @spec matrix_value(map(), String.t(), term()) :: term()
  def matrix_value(suite, key, default) do
    suite |> Map.get("matrix", %{}) |> Map.get(key, Map.get(suite, key, default))
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
