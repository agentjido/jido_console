defmodule Jido.Cli.Extensions.Host do
  @moduledoc "Owns extension host lifecycle and operation routing."

  alias Jido.Cli.Extensions.Setup
  alias Jidoka.Extension.Request

  @doc "Opens one public Jidoka host and compiles its operation sources."
  @spec open(Jidoka.Session.Data.t(), [Request.t()], Setup.t(), :interactive | :automation, keyword()) ::
          {:ok, map()} | {:error, term()}
  def open(session, requests, %{registry: registry} = setup, mode, opts \\ []) do
    if map_size(registry) == 0 do
      {:ok, %{session: session, host: nil, runtime_opts: []}}
    else
      with {:ok, host} <- Jidoka.Extension.Host.open(session, requests, registry, mode) do
        opts = Keyword.put_new(opts, :recover_coding_errors, Map.get(setup, :recover_coding_errors, false))

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
        operations:
          route_operations(
            compiled,
            Keyword.get(opts, :operations),
            Keyword.get(opts, :recover_coding_errors, false)
          ),
        extension_dispatcher: host.dispatcher
      ]

      {:ok, %{session: %{session | spec: spec}, host: host, runtime_opts: runtime_opts}}
    end
  end

  defp put_operations(spec, operations) do
    attrs = spec |> Map.from_struct() |> Map.put(:operations, spec.operations ++ operations)
    Jidoka.Agent.Spec.new(attrs)
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
