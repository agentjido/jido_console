defmodule Jido.Cli.Extensions.Resolver do
  @moduledoc "CLI-owned trusted extension records and project trust resolution."

  alias Jido.Cli.{Digest, Document}
  alias Jido.Cli.Extensions.{Record, Setup, Trust}
  alias Jidoka.Extension.{ProcessHost, Request}

  @record_file_schema Zoi.map(
                        %{
                          "extensions" => Zoi.array(Zoi.map(Zoi.string(), Zoi.json(), [])),
                          "version" => Zoi.enum([1]) |> Zoi.optional()
                        },
                        unrecognized_keys: :error
                      )

  @type setup :: Setup.t()

  @doc "Resolves inert requests to a private registry and portable trust projection."
  @spec resolve([Request.t()], :interactive | :automation, keyword()) ::
          {:ok, setup()} | {:error, term()}
  def resolve([], _mode, _opts),
    do: {:ok, %Setup{registry: %{}, projection: %{"status" => "not_requested"}}}

  def resolve(requests, mode, opts) when is_list(requests) and mode in [:interactive, :automation] do
    case Enum.filter(requests, & &1.enabled) do
      [] ->
        resolve([], mode, opts)

      active_requests ->
        with {:ok, records} <- load_records(opts),
             {:ok, identity} <- project_identity(opts),
             {:ok, selected} <- select_records(active_requests, records, identity, mode, opts),
             {:ok, registry} <- build_registry(selected, identity, mode, opts) do
          projection = %{
            "status" => "trusted",
            "project" => %{"root_digest" => digest(identity.root), "repository_id" => identity.repository_id},
            "records" => Enum.map(selected, &Record.project/1)
          }

          {:ok, %Setup{registry: registry, projection: projection}}
        end
    end
  end

  defp load_records(opts) do
    files = Keyword.get(opts, :extension_record_files, Application.get_env(:jido_cli, :extension_record_files, []))

    files
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case load_record_file(path) do
        {:ok, records} -> {:cont, {:ok, acc ++ records}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reject_duplicates()
  end

  defp load_record_file(path) do
    path = Path.expand(path)

    with {:ok, document, _contents} <- Document.decode_file(path, max_file_bytes: 1_000_000),
         {:ok, document} <- Document.validate(@record_file_schema, document, path),
         records when is_list(records) <- Map.get(document, "extensions", []),
         {:ok, records} <- map_records(records, path) do
      {:ok, records}
    else
      reason -> {:error, {:invalid_extension_record_file, path, reason}}
    end
  end

  defp map_records(records, path) do
    Enum.reduce_while(records, {:ok, []}, fn attrs, {:ok, acc} ->
      case Record.new(attrs, path) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp reject_duplicates({:error, _reason} = error), do: error

  defp reject_duplicates({:ok, records}) do
    duplicate = records |> Enum.frequencies_by(&{&1.scope, &1.id}) |> Enum.find(fn {_key, count} -> count > 1 end)
    if duplicate, do: {:error, {:duplicate_extension_record, elem(duplicate, 0)}}, else: {:ok, records}
  end

  defp project_identity(opts) do
    root = Keyword.get(opts, :project_root, File.cwd!())
    Trust.project_identity(root, opts)
  end

  defp select_records(requests, records, identity, mode, opts) do
    user = Map.new(Enum.filter(records, &(&1.scope == :user)), &{&1.id, &1})
    project = Map.new(Enum.filter(records, &(&1.scope == :project)), &{&1.id, &1})

    requested_project_ids = Enum.filter(requests, &Map.has_key?(project, &1.id)) |> Enum.map(& &1.id)

    with {:ok, trusted} <- project_trust(requested_project_ids, identity, opts) do
      effective = Map.merge(user, project)

      Enum.reduce_while(requests, {:ok, []}, fn request, {:ok, acc} ->
        case select_record(request, effective, trusted, mode) do
          {:ok, record} -> {:cont, {:ok, [record | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, selected} -> {:ok, Enum.reverse(selected)}
        error -> error
      end
    end
  end

  defp select_record(request, effective, trusted, mode) do
    case Map.fetch(effective, request.id) do
      {:ok, record} -> allow_record(record, request.id, trusted, mode)
      :error -> {:error, {:unknown_extension_record, request.id}}
    end
  end

  defp allow_record(%{enabled: false}, id, _trusted, _mode),
    do: {:error, {:extension_record_disabled, id}}

  defp allow_record(record, id, trusted, mode) do
    if mode in record.modes,
      do: allow_record_scope(record, id, trusted),
      else: {:error, {:extension_mode_not_allowed, id, mode}}
  end

  defp allow_record_scope(%{scope: :project} = record, id, trusted) do
    if Map.get(trusted, id) == record.sha256,
      do: {:ok, record},
      else: {:error, {:extension_project_pin_not_trusted, id}}
  end

  defp allow_record_scope(record, _id, _trusted), do: {:ok, record}

  defp project_trust([], _identity, _opts), do: {:ok, %{}}
  defp project_trust(_ids, identity, opts), do: Trust.trusted_extensions(identity, opts)

  defp build_registry(records, identity, mode, opts) do
    Enum.reduce_while(records, {:ok, %{}}, fn record, {:ok, registry} ->
      case registry_entry(record, identity, mode, opts) do
        {:ok, entry} -> {:cont, {:ok, Map.put(registry, record.id, entry)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp registry_entry(%Record{source: :built_in} = record, identity, _mode, opts) do
    resolver = Keyword.get(opts, :built_in_extension_resolver)

    with true <- is_function(resolver, 2),
         {:ok, factory} <- resolver.(record.id, %{project: identity}) do
      {:ok, %{registration: Record.registration(record), factory: factory}}
    else
      reason -> {:error, {:built_in_extension_unavailable, record.id, reason}}
    end
  end

  defp registry_entry(%Record{source: :process} = record, identity, mode, opts) do
    resolver = Keyword.get(opts, :process_extension_descriptor_resolver)

    with :ok <- verify_executable(record, opts),
         true <- is_function(resolver, 2),
         {:ok, descriptor} <- resolver.(record, %{project: identity}),
         true <- is_map(descriptor) do
      {:ok,
       %{
         registration: Record.registration(record),
         factory: ProcessHost.factory(descriptor, mode: mode)
       }}
    else
      reason -> {:error, {:process_extension_unavailable, record.id, reason}}
    end
  end

  defp verify_executable(%Record{command: [executable | _args], sha256: expected}, opts) do
    hash = Keyword.get(opts, :extension_file_hash, &default_hash/1)

    with {:ok, canonical} <- Trust.canonical_path(executable),
         {:ok, actual} <- hash.(canonical),
         true <- actual == expected do
      :ok
    else
      reason -> {:error, {:extension_executable_hash_mismatch, executable, reason}}
    end
  end

  defp default_hash(path) do
    Digest.file(path)
  end

  defp digest(value), do: Digest.portable(value)
end
