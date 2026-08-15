defmodule Jido.Console.Automation.Interrupt do
  @moduledoc """
  Starts and stops an injected automation cancellation source.

  A source receives the coordinator pid and must send cancellation through
  `request/2`. The executable uses the bundled signal source. Tests can inject
  a deterministic source module.
  """

  @message_tag :jido_console_automation_cancel

  @doc "Starts one cancellation source for the specified coordinator."
  @callback start(owner :: pid(), opts :: keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Stops one cancellation source and releases its resources."
  @callback stop(state :: term()) :: :ok

  @doc "Starts the configured cancellation source for an automation coordinator."
  @spec start(pid(), keyword()) :: {:ok, term()} | {:error, term()}
  def start(owner, opts) when is_pid(owner) and is_list(opts) do
    case Keyword.get(opts, :cancellation_source) do
      nil -> {:ok, nil}
      module when is_atom(module) -> start_module(module, owner, opts)
      source when is_function(source, 1) -> normalize_source_start(source.(owner))
      source -> {:error, {:invalid_cancellation_source, source}}
    end
  rescue
    exception -> {:error, {:cancellation_source_failed, exception}}
  catch
    kind, reason -> {:error, {:cancellation_source_failed, {kind, reason}}}
  end

  @doc "Stops a cancellation source and releases its resources."
  @spec stop(term()) :: :ok
  def stop(nil), do: :ok

  def stop({:module, module, state}) do
    case module.stop(state) do
      :ok -> :ok
      _result -> :ok
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  def stop({:function, cleanup}) when is_function(cleanup, 0) do
    _result = cleanup.()
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc "Sends one cancellation request to an automation coordinator."
  @spec request(pid(), term()) :: :ok
  def request(owner, reason \\ :interrupt) when is_pid(owner) do
    send(owner, {@message_tag, reason})
    :ok
  end

  @doc "Returns the message tag used for cancellation requests."
  @spec message_tag() :: atom()
  def message_tag, do: @message_tag

  defp start_module(module, owner, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :start, 2) and
         function_exported?(module, :stop, 1) do
      case module.start(owner, opts) do
        {:ok, state} -> {:ok, {:module, module, state}}
        {:error, _reason} = error -> error
        result -> {:error, {:invalid_cancellation_source_start, module, result}}
      end
    else
      {:error, {:invalid_cancellation_source, module}}
    end
  end

  defp normalize_source_start({:ok, cleanup}) when is_function(cleanup, 0),
    do: {:ok, {:function, cleanup}}

  defp normalize_source_start({:error, _reason} = error), do: error
  defp normalize_source_start(result), do: {:error, {:invalid_cancellation_source_start, result}}
end

defmodule Jido.Console.Automation.Interrupt.Signal do
  @moduledoc """
  Converts an executable `SIGTERM` into cooperative automation cancellation.

  The handler temporarily replaces Erlang's default `SIGTERM` handler while an
  automated command runs. It restores the default handler when the run ends.
  """

  @behaviour Jido.Console.Automation.Interrupt
  @behaviour :gen_event

  alias Jido.Console.Automation.Interrupt

  @signal_server :erl_signal_server
  @default_handler :erl_signal_handler

  @impl Jido.Console.Automation.Interrupt
  @spec start(pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(owner, _opts) when is_pid(owner) do
    case :os.type() do
      {:unix, _name} -> install(owner)
      _other -> {:ok, %{handler: nil, restore_default?: false}}
    end
  end

  @impl Jido.Console.Automation.Interrupt
  @spec stop(map()) :: :ok
  def stop(%{handler: nil}), do: :ok

  def stop(%{handler: handler, restore_default?: restore_default?}) do
    _result = :gen_event.delete_handler(@signal_server, handler, :normal)
    restore_default_handler(restore_default?)
    :ok
  end

  @impl :gen_event
  @spec init(pid()) :: {:ok, pid()}
  def init(owner) when is_pid(owner), do: {:ok, owner}

  @impl :gen_event
  @spec handle_event(term(), pid()) :: {:ok, pid()}
  def handle_event(:sigterm, owner) do
    :ok = Interrupt.request(owner, :sigterm)
    {:ok, owner}
  end

  def handle_event(_event, owner), do: {:ok, owner}

  @impl :gen_event
  @spec handle_call(term(), pid()) :: {:ok, :ok, pid()}
  def handle_call(_request, owner), do: {:ok, :ok, owner}

  @impl :gen_event
  @spec handle_info(term(), pid()) :: {:ok, pid()}
  def handle_info(_message, owner), do: {:ok, owner}

  @impl :gen_event
  @spec terminate(term(), pid()) :: :ok
  def terminate(_reason, _owner), do: :ok

  @impl :gen_event
  @spec code_change(term(), pid(), term()) :: {:ok, pid()}
  def code_change(_old_version, owner, _extra), do: {:ok, owner}

  defp install(owner) do
    handlers = :gen_event.which_handlers(@signal_server)
    restore_default? = @default_handler in handlers

    case maybe_delete_default(restore_default?) do
      :ok ->
        install_after_default_removal(owner, restore_default?)

      {:error, _reason} = error ->
        restore_default_handler(restore_default?)
        error
    end
  end

  defp install_after_default_removal(owner, restore_default?) do
    result =
      try do
        :ok = :os.set_signal(:sigterm, :handle)
        handler = {__MODULE__, make_ref()}

        case :gen_event.add_sup_handler(@signal_server, handler, owner) do
          :ok -> {:ok, %{handler: handler, restore_default?: restore_default?}}
          {:error, reason} -> {:error, {:signal_handler_start_failed, reason}}
        end
      rescue
        exception -> {:error, {:signal_handler_start_failed, exception}}
      catch
        kind, reason -> {:error, {:signal_handler_start_failed, {kind, reason}}}
      end

    case result do
      {:ok, _state} = ok ->
        ok

      {:error, _reason} = error ->
        restore_default_handler(restore_default?)
        error
    end
  end

  defp maybe_delete_default(true) do
    case :gen_event.delete_handler(@signal_server, @default_handler, :normal) do
      :ok -> :ok
      {:error, :module_not_found} -> :ok
      {:error, reason} -> {:error, {:default_signal_handler_delete_failed, reason}}
    end
  end

  defp maybe_delete_default(false), do: :ok

  defp restore_default_handler(true) do
    if @default_handler in :gen_event.which_handlers(@signal_server) do
      :ok
    else
      case :gen_event.add_handler(@signal_server, @default_handler, []) do
        :ok -> :ok
        {:error, _reason} -> :ok
      end
    end
  end

  defp restore_default_handler(false), do: :ok
end
