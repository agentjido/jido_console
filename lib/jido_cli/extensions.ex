defmodule Jido.Cli.Extensions do
  @moduledoc "CLI-owned trusted extension records and project trust resolution."

  alias Jido.Cli.Extensions.{Record, Trust}
  alias Jidoka.Extension.{ProcessHost, Request}

  @type setup :: %{registry: map(), projection: map()}

  @doc "Resolves inert requests to a private registry and portable trust projection."
  @spec resolve([Request.t()], :interactive | :automation, keyword()) ::
          {:ok, setup()} | {:error, term()}
  def resolve([], _mode, _opts), do: {:ok, %{registry: %{}, projection: %{"status" => "not_requested"}}}

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

          {:ok, %{registry: registry, projection: projection}}
        end
    end
  end

  @doc "Opens one public Jidoka host and compiles its operation sources."
  @spec open(Jidoka.Session.Data.t(), [Request.t()], setup(), :interactive | :automation, keyword()) ::
          {:ok, map()} | {:error, term()}
  def open(session, requests, %{registry: registry}, mode, opts \\ []) do
    if map_size(registry) == 0 do
      {:ok, %{session: session, host: nil, runtime_opts: []}}
    else
      with {:ok, host} <- Jidoka.Extension.Host.open(session, requests, registry, mode) do
        case configure_host(session, host, opts) do
          {:ok, runtime} ->
            {:ok, runtime}

          {:error, _reason} = error ->
            Jidoka.Extension.Host.close(host)
            error
        end
      end
    end
  end

  @doc "Returns namespaced extension results and UI data."
  @spec results(Jidoka.Extension.Host.t() | nil) :: {:ok, map()}
  def results(nil), do: {:ok, %{}}

  def results(host) do
    with {:ok, results} <- Jidoka.Extension.Host.results(host),
         {:ok, ui_data} <- Jidoka.Extension.Host.ui_data(host) do
      combined =
        Map.merge(results, ui_data, fn _namespace, result, ui ->
          %{"result" => result, "ui_data" => ui}
        end)

      {:ok, combined}
    end
  end

  @doc "Closes one host."
  @spec close(Jidoka.Extension.Host.t() | nil) :: {:ok, [map()]}
  def close(nil), do: {:ok, []}
  def close(host), do: Jidoka.Extension.Host.close(host)

  defp configure_host(session, host, opts) do
    with {:ok, compiled} <- Jidoka.Operation.Source.compile(Jidoka.Extension.Host.operation_sources(host)),
         {:ok, spec} <- put_operations(session.spec, compiled.operations) do
      runtime_opts = [
        operations: route_operations(compiled, Keyword.get(opts, :operations)),
        extension_dispatcher: host.dispatcher
      ]

      {:ok, %{session: %{session | spec: spec}, host: host, runtime_opts: runtime_opts}}
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

    with {:ok, contents} <- File.read(path),
         {:ok, document} <- decode(path, contents),
         1 <- Map.get(document, "version", 1),
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
        case Map.fetch(effective, request.id) do
          {:ok, record} ->
            cond do
              not record.enabled ->
                {:halt, {:error, {:extension_record_disabled, request.id}}}

              mode not in record.modes ->
                {:halt, {:error, {:extension_mode_not_allowed, request.id, mode}}}

              record.scope == :project and Map.get(trusted, request.id) != record.sha256 ->
                {:halt, {:error, {:extension_project_pin_not_trusted, request.id}}}

              true ->
                {:cont, {:ok, [record | acc]}}
            end

          :error ->
            {:halt, {:error, {:unknown_extension_record, request.id}}}
        end
      end)
      |> case do
        {:ok, selected} -> {:ok, Enum.reverse(selected)}
        error -> error
      end
    end
  end

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

  defp put_operations(spec, operations) do
    attrs = spec |> Map.from_struct() |> Map.put(:operations, spec.operations ++ operations)
    Jidoka.Agent.Spec.new(attrs)
  end

  defp route_operations(compiled, nil), do: compiled.capability

  defp route_operations(compiled, base) when is_function(base, 3) do
    names = MapSet.new(Enum.map(compiled.operations, & &1.name))

    fn intent, journal, context ->
      with {:ok, request} <- Jidoka.Effect.OperationRequest.from_input(intent.payload) do
        if MapSet.member?(names, request.name),
          do: compiled.capability.(intent, journal, context),
          else: base.(intent, journal, context)
      end
    end
  end

  defp default_hash(path) do
    with {:ok, contents} <- File.read(path) do
      {:ok, "sha256:" <> (:crypto.hash(:sha256, contents) |> Base.encode16(case: :lower))}
    end
  end

  defp decode(path, contents) do
    case Path.extname(path) do
      ".json" -> Jason.decode(contents)
      _extension -> YamlElixir.read_from_string(contents, merge_anchors: false)
    end
  end

  defp digest(value), do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
