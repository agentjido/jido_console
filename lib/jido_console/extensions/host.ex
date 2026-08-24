defmodule Jido.Console.Extensions.Host do
  @moduledoc "Owns extension host lifecycle and operation routing."

  alias Jido.Console.Extensions.Setup
  alias Jido.Console.Digest
  alias Jido.Console.Session.Binding
  alias Jidoka.Extension.Request

  @doc "Opens one public Jidoka host and compiles its operation sources."
  @spec open(Jidoka.Session.Data.t(), [Request.t()], Setup.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def open(session, requests, setup, opts \\ []) do
    registry = Setup.registry(setup)

    with {:ok, fingerprint} <- Setup.runtime_definition_fingerprint(setup),
         :ok <- expected_fingerprint(fingerprint, opts) do
      open_registry(session, requests, setup, registry, fingerprint, opts)
    end
  end

  defp open_registry(session, _requests, _setup, registry, fingerprint, _opts)
       when map_size(registry) == 0 do
    {:ok,
     %{
       session: session,
       host: nil,
       runtime_opts: [],
       runtime_definition_fingerprint: fingerprint,
       compiled_operation_fingerprint: operation_fingerprint([])
     }}
  end

  defp open_registry(session, requests, setup, registry, fingerprint, opts) do
    with {:ok, host} <- Jidoka.Extension.Host.open(session, requests, registry, :interactive) do
      opts = Keyword.put_new(opts, :recover_coding_errors, Setup.recover_coding_errors?(setup))
      configure_open_host(session, host, fingerprint, opts)
    end
  end

  defp configure_open_host(session, host, fingerprint, opts) do
    case configure_host(session, host, fingerprint, opts) do
      {:ok, runtime} ->
        {:ok, runtime}

      {:error, _reason} = error ->
        Jidoka.Extension.Host.close(host)
        error
    end
  end

  @doc "Derives a fresh runtime specification from a bound semantic spec."
  @spec derive_runtime_spec(Binding.t() | Jidoka.Agent.Spec.t(), [Jidoka.Agent.Spec.Operation.t()]) ::
          {:ok, Jidoka.Agent.Spec.t()} | {:error, term()}
  def derive_runtime_spec(%Binding{bound_spec: bound_spec}, operations),
    do: derive_runtime_spec(bound_spec, operations)

  def derive_runtime_spec(%Jidoka.Agent.Spec{} = bound_spec, operations) when is_list(operations) do
    attrs =
      bound_spec
      |> Map.from_struct()
      |> Map.put(:operations, bound_spec.operations ++ operations)

    Jidoka.Agent.Spec.new(attrs)
  end

  def derive_runtime_spec(_bound_spec, _operations), do: {:error, :invalid_bound_runtime_spec}

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

  defp configure_host(session, host, fingerprint, opts) do
    sources = Jidoka.Extension.Host.operation_sources(host)

    with :ok <- ensure_source_modules_loaded(sources),
         {:ok, compiled} <- Jidoka.Operation.Source.compile(sources),
         {:ok, spec} <- derive_runtime_spec(session.spec, compiled.operations) do
      runtime_opts = [
        operations:
          route_operations(
            compiled,
            Keyword.get(opts, :operations),
            Keyword.get(opts, :recover_coding_errors, false)
          ),
        extension_dispatcher: host.dispatcher
      ]

      {:ok,
       %{
         session: %{session | spec: spec},
         host: host,
         runtime_opts: runtime_opts,
         runtime_definition_fingerprint: fingerprint,
         compiled_operation_fingerprint: operation_fingerprint(compiled.operations)
       }}
    end
  end

  defp ensure_source_modules_loaded(sources) do
    Enum.reduce_while(List.wrap(sources), :ok, fn %module{}, :ok ->
      case Code.ensure_loaded(module) do
        {:module, ^module} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:operation_source_module_unavailable, module, reason}}}
      end
    end)
  end

  defp expected_fingerprint(fingerprint, opts) do
    case Keyword.get(opts, :expected_runtime_definition_fingerprint) do
      nil -> :ok
      ^fingerprint -> :ok
      _other -> {:error, :runtime_definition_fingerprint_mismatch}
    end
  end

  defp operation_fingerprint(operations) do
    definitions = Enum.map(operations, &Jidoka.project/1)
    Digest.semantic(:compiled_runtime_operations, definitions)
  end

  defp route_operations(compiled, nil, recover?) do
    recover_coding_errors(compiled.capability, recover?)
  end

  defp route_operations(compiled, base, recover?) when is_function(base, 3) do
    names = MapSet.new(Enum.map(compiled.operations, & &1.name))

    capability = fn intent, journal, context ->
      with {:ok, request} <- Jidoka.Effect.OperationRequest.from_input(intent.payload) do
        if MapSet.member?(names, request.name) do
          compiled.capability.(intent, journal, context)
        else
          base.(intent, journal, context)
        end
      end
    end

    recover_coding_errors(capability, recover?)
  end

  defp recover_coding_errors(capability, false), do: capability

  defp recover_coding_errors(capability, true) do
    fn intent, journal, context ->
      case capability.(intent, journal, context) do
        {:error, %Jidoka.CodingPack.Error{} = error} ->
          {:ok,
           %{
             "status" => "error",
             "retryable" => true,
             "code" => Atom.to_string(error.code),
             "details" => error.details
           }}

        result ->
          result
      end
    end
  end
end
