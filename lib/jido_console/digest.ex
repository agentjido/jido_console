defmodule Jido.Console.Digest do
  @moduledoc "Shared SHA-256 helpers for CLI contracts and trusted files."

  @chunk_bytes 64 * 1_024

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
end
