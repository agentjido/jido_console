defmodule Jido.Console.Document do
  @moduledoc "Bounded UTF-8 JSON and YAML document loading for CLI-owned files."

  @default_max_bytes 1_000_000

  @doc "Reads and decodes one bounded JSON or YAML document."
  @spec decode_file(Path.t(), keyword()) :: {:ok, term(), binary()} | {:error, term()}
  def decode_file(path, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, contents} <- read_text(path, opts),
         {:ok, decoded} <- decode(path, contents) do
      {:ok, decoded, contents}
    end
  end

  @doc "Reads one regular UTF-8 file with pre-read and post-read size checks."
  @spec read_text(Path.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_text(path, opts \\ []) when is_binary(path) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_file_bytes, @default_max_bytes)

    with :ok <- valid_limit(max_bytes),
         {:ok, %{type: :regular, size: size}} <- File.stat(path),
         :ok <- within_limit(path, size, max_bytes),
         {:ok, contents} <- File.read(path),
         :ok <- within_limit(path, byte_size(contents), max_bytes),
         true <- String.valid?(contents) do
      {:ok, contents}
    else
      {:ok, stat} ->
        {:error, {:file_read_failed, path, {:not_regular, stat.type}}}

      false ->
        {:error, {:file_read_failed, path, :invalid_utf8}}

      {:error, {:file_too_large, _path, _size, _limit} = reason} ->
        {:error, {:file_read_failed, path, reason}}

      {:error, reason} ->
        {:error, {:file_read_failed, path, reason}}
    end
  end

  @doc "Decodes UTF-8 contents by file extension."
  @spec decode(Path.t(), binary()) :: {:ok, term()} | {:error, term()}
  def decode(path, contents) when is_binary(path) and is_binary(contents) do
    result =
      case String.downcase(Path.extname(path)) do
        ".json" -> Jason.decode(contents)
        _extension -> YamlElixir.read_from_string(contents, merge_anchors: false)
      end

    case result do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:decode_failed, path, reason}}
    end
  rescue
    exception -> {:error, {:decode_failed, path, Exception.message(exception)}}
  end

  @doc "Validates one decoded value through a Zoi schema."
  @spec validate(Zoi.schema(), term(), term()) :: {:ok, term()} | {:error, term()}
  def validate(schema, value, context) do
    case Zoi.parse(schema, value) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, errors} -> {:error, {:document_schema_invalid, context, Zoi.treefy_errors(errors)}}
    end
  end

  defp valid_limit(value) when is_integer(value) and value > 0, do: :ok
  defp valid_limit(value), do: {:error, {:invalid_file_size_limit, value}}

  defp within_limit(_path, size, max_bytes) when size <= max_bytes, do: :ok
  defp within_limit(path, size, max_bytes), do: {:error, {:file_too_large, path, size, max_bytes}}
end
