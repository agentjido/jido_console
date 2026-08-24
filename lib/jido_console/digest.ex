defmodule Jido.Console.Digest do
  @moduledoc "Shared SHA-256 helpers for CLI contracts and trusted files."

  @chunk_bytes 64 * 1_024
  @semantic_version 1

  @doc "Returns a lower-case SHA-256 hexadecimal digest."
  @spec hex(iodata()) :: String.t()
  def hex(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end

  @doc "Returns a portable `sha256:` digest."
  @spec portable(iodata()) :: String.t()
  def portable(value), do: "sha256:" <> hex(value)

  @doc "Returns a version-tagged semantic digest for deterministic host data."
  @spec semantic(atom() | String.t(), term()) :: String.t()
  def semantic(subject, value), do: subject |> semantic_bytes(value) |> portable()

  @doc false
  @spec semantic_bytes(atom() | String.t(), term()) :: binary()
  def semantic_bytes(subject, value) when is_atom(subject) or is_binary(subject) do
    :erlang.term_to_binary(
      {:jido_console_semantic, @semantic_version, subject, canonical(value)},
      [:deterministic, minor_version: 2]
    )
  end

  @doc "Streams one regular file into a portable SHA-256 digest."
  @spec file(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def file(path) when is_binary(path) do
    with {:ok, %{type: :regular}} <- File.stat(path),
         {:ok, device} <- File.open(path, [:read, :binary]) do
      try do
        {:ok, "sha256:" <> stream(device, :crypto.hash_init(:sha256))}
      after
        File.close(device)
      end
    else
      {:ok, stat} -> {:error, {:not_regular_file, stat.type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream(device, context) do
    case IO.binread(device, @chunk_bytes) do
      :eof -> context |> :crypto.hash_final() |> Base.encode16(case: :lower)
      {:error, reason} -> raise File.Error, reason: reason, action: "read", path: "digest input"
      data -> stream(device, :crypto.hash_update(context, data))
    end
  end

  defp canonical(%_{} = struct), do: struct |> Map.from_struct() |> canonical()

  defp canonical(map) when is_map(map) do
    entries =
      map
      |> Enum.map(fn {key, value} -> {canonical(key), canonical(value)} end)
      |> Enum.sort_by(fn {key, _value} -> :erlang.term_to_binary(key, [:deterministic]) end)

    {:map, entries}
  end

  defp canonical(list) when is_list(list), do: {:list, Enum.map(list, &canonical/1)}

  defp canonical(tuple) when is_tuple(tuple) do
    {:tuple, tuple |> Tuple.to_list() |> Enum.map(&canonical/1)}
  end

  defp canonical(value), do: value
end
