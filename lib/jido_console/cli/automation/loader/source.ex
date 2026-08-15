defmodule Jido.Console.Automation.Loader.Source do
  @moduledoc false

  alias Jido.Console.Document
  import Jido.Console.Automation.Loader.Fields, only: [map_value: 2, resolve_path: 2]

  @doc false
  @spec text(term(), Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def text(text, _base_dir, _opts) when is_binary(text) and text != "", do: {:ok, text}

  def text(source, base_dir, opts) when is_map(source) do
    text = Map.get(source, "text")
    file = Map.get(source, "file")

    cond do
      is_binary(text) and not is_nil(file) -> {:error, :multiple_text_sources}
      is_binary(text) and text != "" -> {:ok, text}
      is_binary(file) and file != "" -> read_text(resolve_path(base_dir, file), opts)
      true -> {:error, {:invalid_text_source, source}}
    end
  end

  def text(source, _base_dir, _opts), do: {:error, {:invalid_text_source, source}}

  @doc false
  @spec data(term(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def data(nil, _base_dir, _opts), do: {:ok, %{}}

  def data(source, base_dir, opts) when is_map(source) do
    value? = Map.has_key?(source, "value")
    file = Map.get(source, "file")

    cond do
      value? and not is_nil(file) ->
        {:error, :multiple_data_sources}

      value? ->
        map_value(Map.get(source, "value"), :context)

      is_binary(file) and file != "" ->
        with {:ok, decoded, _contents} <- decode_file(resolve_path(base_dir, file), opts) do
          map_value(decoded, :context)
        end

      true ->
        {:ok, source}
    end
  end

  def data(source, _base_dir, _opts), do: {:error, {:invalid_data_source, source}}

  @doc false
  @spec input_text(String.t(), keyword()) :: {:ok, String.t(), Path.t()} | {:error, term()}
  def input_text("-", opts) do
    device = Keyword.get(opts, :input_device, :stdio)

    case IO.read(device, :eof) do
      text when is_binary(text) -> validate_text(text, "-")
      {:error, reason} -> {:error, {:input_read_failed, reason}}
    end
    |> case do
      {:ok, text} -> {:ok, text, "-"}
      {:error, reason} -> {:error, reason}
    end
  end

  def input_text(path, opts) do
    path = Path.expand(path)

    with {:ok, text} <- read_text(path, opts) do
      {:ok, text, path}
    end
  end

  @doc false
  @spec decode_file(Path.t(), keyword()) :: {:ok, map(), binary()} | {:error, term()}
  def decode_file(path, opts) do
    with {:ok, decoded, contents} <- Document.decode_file(path, opts),
         true <- is_map(decoded) or {:error, {:document_must_be_map, path}} do
      {:ok, decoded, contents}
    end
  end

  @doc false
  @spec read_text(Path.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_text(path, opts), do: Document.read_text(path, opts)

  defp validate_text(text, path) do
    if String.valid?(text), do: {:ok, text}, else: {:error, {:invalid_utf8, path}}
  end
end
