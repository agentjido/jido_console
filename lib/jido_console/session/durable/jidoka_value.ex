defmodule Jido.Console.Session.Durable.JidokaValue do
  @moduledoc "Bounded opaque envelope for one public Jidoka durable-session value."

  alias Jido.Console.Digest
  alias Jido.Console.Session.Durable.{CanonicalJSON, Catalog, Value}
  alias Jidoka.Session.Data

  @schema "jido.console.jidoka-value"
  @version 1
  @atom_tag "$jido.atom"
  @tuple_tag "$jido.tuple"
  @fields ~w(schema version jidoka_schema_version jidoka_revision encoded_value encoded_value_bytes value_digest)

  @type encoded :: %{
          envelope: map(),
          bytes: binary(),
          digest: String.t(),
          encoded_bytes: non_neg_integer(),
          value: Data.t()
        }

  @doc "Validates one supported Jidoka value before a storage transaction starts."
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(value) do
    Value.validate(value, allow_struct: &portable_struct?/1, allow_local_fields: true)
  end

  @doc "Encodes one Jidoka session value after structural admission checks."
  @spec encode(Data.t(), keyword()) :: {:ok, encoded()} | {:error, term()}
  def encode(session, opts \\ [])

  def encode(%Data{} = session, opts) do
    limit = Keyword.get_lazy(opts, :max_bytes, fn -> Catalog.limit("jidoka_value_bytes") |> elem(1) end)

    with :ok <- validate(session),
         {:ok, portable} <- portable(session),
         {:ok, value_bytes} <- CanonicalJSON.encode(portable),
         :ok <- within_limit(value_bytes, limit),
         envelope <- envelope(session, portable, value_bytes),
         {:ok, bytes} <- CanonicalJSON.encode(envelope) do
      {:ok,
       %{
         envelope: envelope,
         bytes: bytes,
         digest: Digest.portable(bytes),
         encoded_bytes: byte_size(bytes),
         value: session
       }}
    end
  end

  def encode(_session, _opts), do: {:error, :invalid_jidoka_value}

  @doc "Decodes one envelope and finishes with the public Jidoka session schema."
  @spec decode(binary(), keyword()) :: {:ok, encoded()} | {:error, term()}
  def decode(bytes, opts \\ [])

  def decode(bytes, opts) when is_binary(bytes) do
    limit = Keyword.get_lazy(opts, :max_bytes, fn -> Catalog.limit("jidoka_value_bytes") |> elem(1) end)

    with {:ok, envelope} <- CanonicalJSON.decode(bytes),
         :ok <- validate_envelope(envelope),
         {:ok, value_bytes} <- CanonicalJSON.encode(envelope["encoded_value"]),
         :ok <- within_limit(value_bytes, limit),
         :ok <- validate_value_identity(envelope, value_bytes),
         {:ok, value} <- restore(envelope["encoded_value"]),
         {:ok, %Data{} = session} <- public_jidoka_validation(value),
         :ok <- validate_public_identity(envelope, session) do
      {:ok,
       %{
         envelope: envelope,
         bytes: bytes,
         digest: Digest.portable(bytes),
         encoded_bytes: byte_size(bytes),
         value: session
       }}
    else
      {:error, :noncanonical_json} -> {:error, :noncanonical_jidoka_envelope}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode(_bytes, _opts), do: {:error, :invalid_jidoka_value_bytes}

  defp envelope(session, portable, value_bytes) do
    %{
      "schema" => @schema,
      "version" => @version,
      "jidoka_schema_version" => session.schema_version,
      "jidoka_revision" => session.revision,
      "encoded_value" => portable,
      "encoded_value_bytes" => byte_size(value_bytes),
      "value_digest" => Digest.portable(value_bytes)
    }
  end

  defp validate_envelope(envelope) when is_map(envelope) do
    missing = @fields -- Map.keys(envelope)
    unknown = Map.keys(envelope) -- @fields

    cond do
      missing != [] -> {:error, {:missing_jidoka_envelope_fields, Enum.sort(missing)}}
      unknown != [] -> {:error, {:unknown_jidoka_envelope_fields, Enum.sort(unknown)}}
      envelope["schema"] != @schema -> {:error, :incompatible_jidoka_envelope}
      envelope["version"] != @version -> {:error, :incompatible_jidoka_envelope}
      not is_integer(envelope["jidoka_schema_version"]) -> {:error, :invalid_jidoka_schema_version}
      not is_integer(envelope["jidoka_revision"]) -> {:error, :invalid_jidoka_revision}
      not is_map(envelope["encoded_value"]) -> {:error, :invalid_jidoka_value}
      true -> :ok
    end
  end

  defp validate_envelope(_envelope), do: {:error, :invalid_jidoka_envelope}

  defp validate_value_identity(envelope, value_bytes) do
    cond do
      envelope["encoded_value_bytes"] != byte_size(value_bytes) -> {:error, :jidoka_value_size_mismatch}
      envelope["value_digest"] != Digest.portable(value_bytes) -> {:error, :jidoka_value_digest_mismatch}
      true -> :ok
    end
  end

  defp validate_public_identity(envelope, session) do
    cond do
      envelope["jidoka_schema_version"] != session.schema_version -> {:error, :jidoka_schema_version_mismatch}
      envelope["jidoka_revision"] != session.revision -> {:error, :jidoka_revision_mismatch}
      true -> :ok
    end
  end

  defp public_jidoka_validation(value) do
    case Data.new(value) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, {:invalid_jidoka_value, reason}}
    end
  end

  defp within_limit(bytes, limit) when is_integer(limit) and limit > 0 do
    if byte_size(bytes) <= limit,
      do: :ok,
      else: {:error, {:oversized_jidoka_value, byte_size(bytes), limit}}
  end

  defp portable(%module{} = value) do
    if portable_struct?(module), do: portable(Map.from_struct(value)), else: {:error, {:forbidden_struct, module}}
  end

  defp portable(value) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn {key, item}, {:ok, result} ->
      with {:ok, key} <- portable_key(key),
           false <- String.starts_with?(key, "$jido."),
           {:ok, item} <- portable(item) do
        {:cont, {:ok, Map.put(result, key, item)}}
      else
        true -> {:halt, {:error, {:reserved_jidoka_key, key}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp portable(value) when is_list(value), do: portable_list(value)

  defp portable(value) when is_tuple(value) do
    with {:ok, items} <- value |> Tuple.to_list() |> portable_list(),
         do: {:ok, %{@tuple_tag => items}}
  end

  defp portable(value) when is_atom(value) and value not in [nil, true, false],
    do: {:ok, %{@atom_tag => Atom.to_string(value)}}

  defp portable(value) when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
    do: {:ok, value}

  defp portable(_value), do: {:error, :nonportable_jidoka_value}

  defp portable_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, result} ->
      case portable(value) do
        {:ok, value} -> {:cont, {:ok, [value | result]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end)
  end

  defp portable_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp portable_key(key) when is_binary(key) and key != "", do: {:ok, key}
  defp portable_key(key), do: {:error, {:invalid_jidoka_key, inspect(key)}}

  defp restore(%{@atom_tag => atom} = value) when map_size(value) == 1 and is_binary(atom) do
    try do
      {:ok, String.to_existing_atom(atom)}
    rescue
      ArgumentError -> {:error, {:unknown_jidoka_atom, atom}}
    end
  end

  defp restore(%{@tuple_tag => values} = value) when map_size(value) == 1 and is_list(values) do
    with {:ok, values} <- restore_list(values), do: {:ok, List.to_tuple(values)}
  end

  defp restore(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, result} ->
      case restore(item) do
        {:ok, item} -> {:cont, {:ok, Map.put(result, key, item)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp restore(value) when is_list(value), do: restore_list(value)

  defp restore(value) when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
    do: {:ok, value}

  defp restore(_value), do: {:error, :invalid_portable_jidoka_value}

  defp restore_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, result} ->
      case restore(value) do
        {:ok, value} -> {:cont, {:ok, [value | result]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end)
  end

  defp portable_struct?(module) do
    name = Atom.to_string(module)
    String.starts_with?(name, "Elixir.Jidoka.") or module == LLMDB.Model
  end
end
