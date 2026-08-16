defmodule Jido.Console.Session.Protocol do
  @moduledoc """
  Canonical Jido Console session protocol.

  The versioned schema in `priv/session/protocol/jido.session.v1.json` is the
  source of truth for command, event, interaction, outcome, snapshot, replay,
  and control families. This module loads that schema and answers compatibility,
  locality, bound, and authority questions. It does not generate language
  bindings or own a live session.
  """

  @schema_name "jido.session.v1.json"
  @schema_source Path.expand("../../../priv/session/protocol/#{@schema_name}", __DIR__)
  @external_resource @schema_source
  @schema_contents File.read!(@schema_source)
  @families ~w(command event interaction response outcome snapshot replay control)
  @required_type_keys ~w(locality fields)
  @shared "shared"
  @client_local "client_local"

  @type schema :: map()
  @type family :: String.t()
  @type type_name :: String.t()
  @type locality :: String.t()

  @doc "Loads the canonical protocol schema embedded at compile time or from an explicit path."
  @spec schema(keyword()) :: {:ok, schema()} | {:error, term()}
  def schema(opts \\ []) do
    with {:ok, contents} <- schema_contents(opts),
         {:ok, decoded} <- Jason.decode(contents) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:protocol_schema_invalid, Exception.message(error)}}
      {:error, reason} -> {:error, {:protocol_schema_unreadable, reason}}
    end
  end

  defp schema_contents(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} -> File.read(path)
      :error -> {:ok, @schema_contents}
    end
  end

  @doc "Returns the canonical schema path."
  @spec schema_path() :: Path.t()
  def schema_path do
    :jido_console
    |> :code.priv_dir()
    |> List.to_string()
    |> Path.join("session/protocol/#{@schema_name}")
  end

  @doc "Returns the protocol name and version."
  @spec identity(schema()) :: {:ok, %{protocol: String.t(), version: String.t()}} | {:error, term()}
  def identity(%{"protocol" => protocol, "version" => version})
      when is_binary(protocol) and is_binary(version) do
    {:ok, %{protocol: protocol, version: version}}
  end

  def identity(_schema), do: {:error, :protocol_identity_missing}

  @doc "Returns the compatibility rule for the protocol or one family."
  @spec compatibility(schema(), family() | :protocol) :: {:ok, map()} | {:error, term()}
  def compatibility(%{"compatibility" => rule}, :protocol) when is_map(rule), do: {:ok, rule}

  def compatibility(schema, family) when is_binary(family) do
    case family_entry(schema, family) do
      {:ok, %{"version" => version, "compatibility" => rule}} ->
        {:ok, %{"version" => version, "compatibility" => rule}}

      {:error, _reason} = error ->
        error
    end
  end

  def compatibility(_schema, _target), do: {:error, :protocol_compatibility_missing}

  @doc "Returns declared protocol families."
  @spec families() :: [family()]
  def families, do: @families

  @doc "Returns type names for one family."
  @spec types(schema(), family()) :: {:ok, [type_name()]} | {:error, term()}
  def types(schema, family) do
    with {:ok, entry} <- family_entry(schema, family),
         {:ok, types} <- fetch_types(entry) do
      {:ok, Map.keys(types) |> Enum.sort()}
    end
  end

  @doc "Returns one type declaration."
  @spec type(schema(), family(), type_name()) :: {:ok, map()} | {:error, term()}
  def type(schema, family, name) do
    with {:ok, entry} <- family_entry(schema, family),
         {:ok, types} <- fetch_types(entry) do
      case Map.fetch(types, name) do
        {:ok, declaration} -> {:ok, declaration}
        :error -> {:error, {:unknown_protocol_type, family, name}}
      end
    end
  end

  @doc "Returns whether a type is shared session state or client-local."
  @spec locality(schema(), family(), type_name()) :: {:ok, locality()} | {:error, term()}
  def locality(schema, family, name) do
    with {:ok, declaration} <- type(schema, family, name) do
      case declaration do
        %{"locality" => locality} when locality in [@shared, @client_local] -> {:ok, locality}
        _other -> {:error, {:protocol_locality_missing, family, name}}
      end
    end
  end

  @doc "Returns true when a type may enter shared session state."
  @spec shared?(schema(), family(), type_name()) :: boolean()
  def shared?(schema, family, name) do
    locality(schema, family, name) == {:ok, @shared}
  end

  @doc "Returns client-local field names that cannot enter shared session state."
  @spec client_local_fields(schema()) :: [String.t()]
  def client_local_fields(%{"client_local_fields" => fields}) when is_list(fields) do
    Enum.filter(fields, &is_binary/1)
  end

  def client_local_fields(_schema), do: []

  @doc "Returns size and unknown-data bounds."
  @spec bounds(schema()) :: {:ok, map()} | {:error, term()}
  def bounds(%{"bounds" => bounds}) when is_map(bounds), do: {:ok, bounds}
  def bounds(_schema), do: {:error, :protocol_bounds_missing}

  @doc "Returns the authority review record."
  @spec authority(schema()) :: {:ok, map()} | {:error, term()}
  def authority(%{"authority" => authority}) when is_map(authority), do: {:ok, authority}
  def authority(_schema), do: {:error, :protocol_authority_missing}

  @doc "Returns true when a field name can grant authority."
  @spec authority_field?(schema(), String.t()) :: boolean()
  def authority_field?(schema, field) when is_binary(field) do
    case authority(schema) do
      {:ok, %{"authority_fields" => fields}} when is_list(fields) -> field in fields
      _other -> false
    end
  end

  @doc "Returns sources that must never grant authority."
  @spec never_grant_from(schema()) :: [String.t()]
  def never_grant_from(schema) do
    case authority(schema) do
      {:ok, %{"never_grant_from" => sources}} when is_list(sources) -> sources
      _other -> []
    end
  end

  @doc "Builds a JSON-compatible envelope for a declared type."
  @spec envelope(schema(), family(), type_name(), map()) :: {:ok, map()} | {:error, term()}
  def envelope(schema, family, name, attrs \\ %{}) when is_map(attrs) do
    with {:ok, identity} <- identity(schema),
         {:ok, _declaration} <- type(schema, family, name),
         :ok <- reject_client_local_leak(schema, family, name, attrs),
         :ok <- reject_authority_from_descriptor(schema, attrs) do
      {:ok,
       %{
         "protocol" => identity.protocol,
         "version" => identity.version,
         "family" => family,
         "type" => name,
         "id" => Map.get(attrs, "id", generated_id(family)),
         "session_id" => Map.get(attrs, "session_id"),
         "created_at" => Map.get(attrs, "created_at"),
         "payload" => Map.drop(attrs, ["id", "session_id", "created_at"])
       }}
    end
  end

  @doc "Encodes a protocol value as JSON."
  @spec encode(map()) :: {:ok, String.t()} | {:error, term()}
  def encode(value) when is_map(value) do
    Jason.encode(value)
  rescue
    exception -> {:error, {:protocol_json_invalid, Exception.message(exception)}}
  end

  @doc "Decodes JSON into a protocol map."
  @spec decode(String.t()) :: {:ok, map()} | {:error, term()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, :protocol_json_not_object}
      {:error, reason} -> {:error, {:protocol_json_invalid, reason}}
    end
  end

  @doc "Reviews the schema for missing families, versions, locality, bounds, and authority leaks."
  @spec review(schema()) :: :ok | {:error, [term()]}
  def review(schema) when is_map(schema) do
    defects =
      []
      |> review_identity(schema)
      |> review_families(schema)
      |> review_bounds(schema)
      |> review_authority(schema)

    if defects == [], do: :ok, else: {:error, Enum.reverse(defects)}
  end

  defp schema_family(%{"families" => families}, family) when is_map(families), do: Map.fetch(families, family)
  defp schema_family(_schema, _family), do: :error

  defp family_entry(schema, family) do
    case schema_family(schema, family) do
      {:ok, entry} when is_map(entry) -> {:ok, entry}
      :error -> {:error, {:unknown_protocol_family, family}}
    end
  end

  defp fetch_types(%{"types" => types}) when is_map(types), do: {:ok, types}
  defp fetch_types(_entry), do: {:error, :protocol_types_missing}

  defp reject_client_local_leak(schema, family, name, attrs) do
    local_fields = MapSet.new(client_local_fields(schema))

    cond do
      not shared?(schema, family, name) ->
        :ok

      Enum.any?(Map.keys(attrs), &MapSet.member?(local_fields, &1)) ->
        {:error, {:client_local_forbidden, family, name}}

      true ->
        :ok
    end
  end

  defp reject_authority_from_descriptor(schema, attrs) do
    forbidden = never_grant_from(schema)

    if Map.has_key?(attrs, "authority_from") and attrs["authority_from"] in forbidden do
      {:error, {:authority_from_forbidden, attrs["authority_from"]}}
    else
      :ok
    end
  end

  defp review_identity(defects, schema) do
    case identity(schema) do
      {:ok, _identity} -> defects
      {:error, reason} -> [reason | defects]
    end
  end

  defp review_families(defects, schema) do
    Enum.reduce(@families, defects, fn family, acc ->
      case family_entry(schema, family) do
        {:ok, entry} -> review_family(acc, family, entry)
        {:error, reason} -> [reason | acc]
      end
    end)
  end

  defp review_family(defects, family, entry) do
    defects =
      cond do
        not is_binary(entry["version"]) -> [{:family_version_missing, family} | defects]
        entry["compatibility"] != "additive" -> [{:family_compatibility_invalid, family} | defects]
        true -> defects
      end

    case fetch_types(entry) do
      {:ok, types} -> Enum.reduce(types, defects, &review_type(&2, family, &1))
      {:error, reason} -> [reason | defects]
    end
  end

  defp review_type(defects, family, {name, declaration}) when is_map(declaration) do
    missing = Enum.reject(@required_type_keys, &Map.has_key?(declaration, &1))

    defects =
      if missing == [], do: defects, else: [{:type_incomplete, family, name, missing} | defects]

    case declaration["locality"] do
      locality when locality in [@shared, @client_local] -> defects
      _other -> [{:type_locality_invalid, family, name} | defects]
    end
  end

  defp review_type(defects, family, {name, _declaration}) do
    [{:type_invalid, family, name} | defects]
  end

  defp review_bounds(defects, schema) do
    case bounds(schema) do
      {:ok, bounds} ->
        required = ~w(max_identity_bytes max_string_bytes max_text_bytes max_unknown_bytes)
        missing = Enum.reject(required, &Map.has_key?(bounds, &1))
        if missing == [], do: defects, else: [{:bounds_incomplete, missing} | defects]

      {:error, reason} ->
        [reason | defects]
    end
  end

  defp review_authority(defects, schema) do
    required_denials = ["renderer", "transport", "host", "origin"]

    case authority(schema) do
      {:ok, authority} ->
        denied = List.wrap(authority["never_grant_from"])
        missing = required_denials -- denied
        if missing == [], do: defects, else: [{:authority_denial_incomplete, missing} | defects]

      {:error, reason} ->
        [reason | defects]
    end
  end

  defp generated_id(family) do
    "plt_#{family}_#{System.unique_integer([:positive])}"
  end
end
