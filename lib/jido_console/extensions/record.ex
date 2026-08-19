defmodule Jido.Console.Extensions.Record do
  @moduledoc "Trusted CLI extension record. Process launch data stays private."

  alias Jidoka.Extension.{CapabilitySet, Identity, PermissionSet, Registration}

  @version 1
  @struct_schema Zoi.struct(
                   __MODULE__,
                   %{
                     version: Zoi.literal(@version) |> Zoi.optional() |> Zoi.default(@version),
                     id: Zoi.string(),
                     source: Zoi.enum([:built_in, :process]),
                     source_ref: Zoi.string(),
                     release: Zoi.string(),
                     sha256: Zoi.string(),
                     permissions: Zoi.array(Zoi.string()) |> Zoi.required() |> Zoi.default([]),
                     capabilities: Zoi.array(Zoi.string()) |> Zoi.required() |> Zoi.default([]),
                     scope: Zoi.enum([:user, :project]),
                     enabled: Zoi.boolean() |> Zoi.optional() |> Zoi.default(true),
                     command: Zoi.array(Zoi.string()) |> Zoi.nullish(),
                     record_path: Zoi.string() |> Zoi.nullish()
                   },
                   unrecognized_keys: :error
                 )

  @enforce_keys Zoi.Struct.enforce_keys(@struct_schema)
  defstruct Zoi.Struct.struct_fields(@struct_schema)

  @type t :: %__MODULE__{}

  @doc "Builds one trusted record from decoded host configuration."
  @spec new(map(), String.t()) :: {:ok, t()} | {:error, term()}
  def new(attrs, record_path) when is_map(attrs) and is_binary(record_path) do
    with {:ok, attrs} <- Jido.Console.Document.validate(schema(), attrs, record_path),
         id when is_binary(id) <- Map.get(attrs, "id"),
         true <- Identity.valid_id?(id),
         {:ok, source} <- enum(Map.get(attrs, "source"), ~w(built_in process)),
         source_ref when is_binary(source_ref) <- Map.get(attrs, "source_ref"),
         release when is_binary(release) <- Map.get(attrs, "release"),
         sha256 when is_binary(sha256) <- Map.get(attrs, "sha256"),
         {:ok, permissions} <- PermissionSet.new(Map.get(attrs, "permissions", [])),
         {:ok, capabilities} <- CapabilitySet.new(Map.get(attrs, "capabilities", [])),
         {:ok, scope} <- enum(Map.get(attrs, "scope", "user"), ~w(user project)),
         enabled when is_boolean(enabled) <- Map.get(attrs, "enabled", true),
         {:ok, command} <- command(source, Map.get(attrs, "command"), record_path) do
      {:ok,
       %__MODULE__{
         id: id,
         source: source,
         source_ref: source_ref,
         release: release,
         sha256: sha256,
         permissions: permissions.values,
         capabilities: capabilities.values,
         scope: scope,
         enabled: enabled,
         command: command,
         record_path: record_path
       }}
    else
      reason -> {:error, {:invalid_extension_record, record_path, reason}}
    end
  end

  @doc "Converts a record to the portable Jidoka registration."
  @spec registration(t()) :: Registration.t()
  def registration(%__MODULE__{} = record) do
    Registration.new!(%{
      identity: %{
        id: record.id,
        source_type: record.source,
        source_ref: record.source_ref,
        release: record.release,
        content_hash: record.sha256,
        trust: :trusted
      },
      permissions: record.permissions,
      capabilities: record.capabilities,
      modes: [:interactive],
      enabled: record.enabled,
      protocol_version: 1
    })
  end

  @doc "Projects trust facts without process launch data or host paths."
  @spec project(t()) :: map()
  def project(%__MODULE__{} = record) do
    %{
      "id" => record.id,
      "source" => Atom.to_string(record.source),
      "release" => record.release,
      "sha256" => record.sha256,
      "permissions" => record.permissions,
      "capabilities" => record.capabilities,
      "scope" => Atom.to_string(record.scope),
      "enabled" => record.enabled
    }
  end

  defp enum(value, values) do
    if value in values,
      do: {:ok, String.to_existing_atom(value)},
      else: {:error, {:invalid_extension_record_enum, value}}
  end

  defp command(:built_in, nil, _record_path), do: {:ok, nil}
  defp command(:built_in, _command, _record_path), do: {:error, :built_in_command_forbidden}

  defp command(:process, [executable | _args] = command, record_path)
       when is_binary(executable) do
    if Enum.all?(command, &is_binary/1) do
      executable =
        if Path.type(executable) == :absolute,
          do: executable,
          else: Path.expand(executable, Path.dirname(record_path))

      {:ok, [executable | tl(command)]}
    else
      {:error, :invalid_process_command}
    end
  end

  defp command(:process, _command, _record_path), do: {:error, :process_command_required}

  defp schema do
    Zoi.map(
      %{
        "capabilities" => Zoi.array(Jido.Console.Document.non_empty_string()) |> Zoi.optional(),
        "command" => Zoi.array(Jido.Console.Document.non_empty_string()) |> Zoi.nullish() |> Zoi.optional(),
        "enabled" => Zoi.boolean() |> Zoi.optional(),
        "id" => Jido.Console.Document.non_empty_string(),
        "permissions" => Zoi.array(Jido.Console.Document.non_empty_string()) |> Zoi.optional(),
        "release" => Jido.Console.Document.non_empty_string(),
        "scope" => Zoi.enum(~w(user project)) |> Zoi.optional(),
        "sha256" => Jido.Console.Document.sha256_digest(),
        "source" => Zoi.enum(~w(built_in process)),
        "source_ref" => Jido.Console.Document.non_empty_string()
      },
      unrecognized_keys: :error
    )
  end
end
