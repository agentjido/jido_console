defmodule Jido.Console.Extensions.Record do
  @moduledoc "Trusted CLI extension record. Process launch data stays private."

  alias Jidoka.Extension.{CapabilitySet, Identity, PermissionSet, Registration}

  @version 1
  @enforce_keys [:id, :source, :source_ref, :release, :sha256, :permissions, :capabilities, :modes, :scope]
  defstruct version: @version,
            id: nil,
            source: nil,
            source_ref: nil,
            release: nil,
            sha256: nil,
            permissions: [],
            capabilities: [],
            modes: [],
            scope: nil,
            enabled: true,
            command: nil,
            record_path: nil

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
         {:ok, modes} <- modes(Map.get(attrs, "modes", ["interactive", "automation"])),
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
         modes: modes,
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
      modes: record.modes,
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
      "modes" => Enum.map(record.modes, &Atom.to_string/1),
      "scope" => Atom.to_string(record.scope),
      "enabled" => record.enabled
    }
  end

  defp enum(value, values) do
    if value in values,
      do: {:ok, String.to_existing_atom(value)},
      else: {:error, {:invalid_extension_record_enum, value}}
  end

  defp modes(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case enum(value, ~w(interactive automation)) do
        {:ok, mode} -> {:cont, {:ok, [mode | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :empty_extension_modes}
      {:ok, modes} -> {:ok, Enum.reverse(modes) |> Enum.uniq()}
      error -> error
    end
  end

  defp modes(value), do: {:error, {:invalid_extension_modes, value}}

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
        "capabilities" => Zoi.array(non_empty_string()) |> Zoi.optional(),
        "command" => Zoi.array(non_empty_string()) |> Zoi.nullish() |> Zoi.optional(),
        "enabled" => Zoi.boolean() |> Zoi.optional(),
        "id" => non_empty_string(),
        "modes" => Zoi.array(Zoi.enum(~w(interactive automation))) |> Zoi.optional(),
        "permissions" => Zoi.array(non_empty_string()) |> Zoi.optional(),
        "release" => non_empty_string(),
        "scope" => Zoi.enum(~w(user project)) |> Zoi.optional(),
        "sha256" => Zoi.string() |> Zoi.regex(Regex.compile!("^sha256:[0-9a-f]{64}$")),
        "source" => Zoi.enum(~w(built_in process)),
        "source_ref" => non_empty_string()
      },
      unrecognized_keys: :error
    )
  end

  defp non_empty_string, do: Zoi.string() |> Zoi.regex(Regex.compile!("\\S"))
end
