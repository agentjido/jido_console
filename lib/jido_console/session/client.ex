defmodule Jido.Console.Session.Client do
  @moduledoc """
  Public renderer-neutral contract for one supervised semantic session.

  All live output uses bounded pull delivery. Acknowledgement and recovery
  receipts are process-lifetime data. They do not survive application restart.
  """

  import Kernel, except: [send: 2]

  alias Jido.Console.Session.{Catalog, Effect, Input, Request}
  alias Jido.Console.Session.Client.{Driver, Handle, Local}

  @type t :: Handle.t()
  @type attach_result :: %{
          handle: t(),
          capabilities: map(),
          snapshot: map()
        }

  @doc "Attaches one exact logical client and returns its bounded baseline."
  @spec attach(String.t(), keyword()) :: {:ok, attach_result()} | {:error, term()}
  def attach(session_id, opts \\ []) do
    driver = Keyword.get(opts, :driver, Local)

    with {:ok, handle, snapshot} <- driver.attach(session_id, opts) do
      {:ok,
       %{
         handle: handle,
         capabilities: driver.capabilities(handle),
         snapshot: snapshot
       }}
    end
  end

  @doc "Detaches only the exact attachment in the handle."
  @spec detach(t()) :: :ok | {:error, term()}
  def detach(handle), do: driver(handle).detach(handle)

  @doc "Queues an exact detach for compatibility with a stopping local client."
  @spec detach_async(t()) :: :ok
  def detach_async(handle) do
    _result = Task.start(fn -> detach(handle) end)
    :ok
  end

  @doc "Admits normal input as a distinct operation."
  @spec send(t(), String.t()) :: {:ok, Input.t()} | {:error, term()}
  def send(handle, text), do: admit(handle, :send, text)

  @doc "Admits immediate steering input as a distinct operation."
  @spec steer(t(), String.t()) :: {:ok, Input.t()} | {:error, term()}
  def steer(handle, text), do: admit(handle, :steer, text)

  @doc "Admits follow-up input as a distinct operation."
  @spec queue(t(), String.t()) :: {:ok, Input.t()} | {:error, term()}
  def queue(handle, text), do: admit(handle, :queue, text)

  @doc "Removes one exact input from a named input queue."
  @spec remove(t(), :steering | :follow_up, String.t()) :: {:ok, map()} | {:error, term()}
  def remove(handle, queue, input_id) do
    driver(handle).input(handle, :remove, %{queue: queue, input_id: input_id})
  end

  @doc "Compatibility name for normal input admission."
  @spec send_input(t(), String.t()) :: {:ok, Input.t()} | {:error, term()}
  def send_input(handle, text), do: send(handle, text)

  @doc "Invokes one catalog command and emits its typed effect on normal output."
  @spec invoke(t(), String.t(), keyword()) :: {:ok, Effect.t()} | {:error, term()}
  def invoke(handle, command_id, opts \\ []) do
    catalog = Handle.catalog(handle)
    identity = Handle.identity(handle)

    with {:ok, command} <- Catalog.fetch_command(catalog, command_id),
         {:ok, effect} <-
           Effect.new(
             outcome: Keyword.get(opts, :outcome, :accepted),
             command_id: command["id"],
             session_id: identity.session_id,
             run_id: Keyword.get(opts, :run_id),
             request_id: Keyword.get(opts, :request_id),
             provenance: command["provenance"],
             reason: Keyword.get(opts, :reason),
             data: Keyword.get(opts, :data, %{})
           ) do
      driver(handle).control(handle, {:effect, effect})
    end
  end

  @doc "Pulls one bounded canonical output batch, a gap, or no output."
  @spec output(t()) :: {:ok, map()} | {:gap, map()} | :empty | {:error, term()}
  def output(handle), do: driver(handle).output(handle)

  @doc "Acknowledges one exact opaque batch token."
  @spec ack(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def ack(handle, token), do: driver(handle).delivery(handle, token)

  @doc "Returns bounded renderer-neutral status for the exact attachment."
  @spec status(t()) :: {:ok, map()} | {:error, term()}
  def status(handle), do: driver(handle).state(handle, :status)

  @doc "Returns a bounded renderer-neutral semantic snapshot."
  @spec snapshot(t()) :: {:ok, map()} | {:error, term()}
  def snapshot(handle), do: driver(handle).state(handle, :snapshot)

  @doc "Requests cancellation for exact session work."
  @spec cancel(t(), Request.t(), keyword()) :: {:ok, :requested} | {:error, term()}
  def cancel(handle, request, opts \\ []) do
    driver(handle).control(handle, {:cancel, request, opts})
  end

  @doc "Approves one exact pending permission or review request."
  @spec approve(t(), Request.t(), term(), keyword()) :: {:ok, :requested} | {:error, term()}
  def approve(handle, request, review, opts \\ []) do
    driver(handle).control(handle, {:respond_review, :approve, request, review, opts})
  end

  @doc "Rejects one exact pending permission or review request."
  @spec reject(t(), Request.t(), term(), keyword()) :: {:ok, :requested} | {:error, term()}
  def reject(handle, request, review, opts \\ []) do
    driver(handle).control(handle, {:respond_review, :deny, request, review, opts})
  end

  @doc "Begins recovery for the exact current delivery gap."
  @spec recover(t(), map() | String.t()) :: {:ok, map()} | {:error, term()}
  def recover(handle, gap) do
    gap_id = if is_map(gap), do: get_in(gap, ["payload", "gap_id"]), else: gap
    driver(handle).recovery(handle, :recover, gap_id)
  end

  @doc false
  @spec recover(t()) :: {:ok, map()} | {:error, term()}
  def recover(handle) do
    case output(handle) do
      {:gap, gap} -> recover(handle, gap)
      {:error, reason} -> {:error, reason}
      _other -> {:error, :recovery_not_required}
    end
  end

  @doc "Returns the one bounded suffix for an active recovery transaction."
  @spec replay(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def replay(handle, recovery_token) do
    driver(handle).recovery(handle, :replay, recovery_token)
  end

  @doc "Completes recovery with the exact opaque completion token."
  @spec resume(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resume(handle, completion_token) do
    driver(handle).recovery(handle, :resume, completion_token)
  end

  @doc "Returns negotiated descriptive capabilities for this attachment."
  @spec capabilities(t()) :: {:ok, map()} | {:error, term()}
  def capabilities(handle) do
    with {:ok, _status} <- driver(handle).state(handle, :status) do
      {:ok, driver(handle).capabilities(handle)}
    end
  end

  @doc "Returns true when one negotiated operation is described as supported."
  @spec supports?(t(), String.t() | atom()) :: {:ok, boolean()} | {:error, term()}
  def supports?(handle, capability) do
    name = if is_atom(capability), do: Atom.to_string(capability), else: capability

    with {:ok, capabilities} <- capabilities(handle) do
      {:ok, name in capabilities["operations"]}
    end
  end

  @doc "Returns the fixed operation names used by client descriptors."
  @spec operation_capabilities() :: [String.t()]
  def operation_capabilities, do: Driver.operation_capabilities()

  @doc "Returns the process-lifetime durability boundary."
  @spec limitation() :: String.t()
  def limitation do
    "Acknowledgement and recovery are process-lifetime only and do not survive application restart."
  end

  @doc false
  @spec configure_runtime(t(), module(), term(), keyword()) :: :ok | {:error, term()}
  def configure_runtime(handle, runtime, agent, opts \\ []) do
    Local.call(handle, {:configure_runtime, runtime, agent, opts})
  end

  @doc false
  @spec runtime_info(t()) :: {:ok, map()} | {:error, term()}
  def runtime_info(handle), do: Local.call(handle, :runtime_info)

  @doc false
  @spec start_turn(t(), String.t(), keyword()) :: {:ok, Request.t()} | {:error, term()}
  def start_turn(handle, prompt, opts \\ []) do
    Local.call(handle, {:start_turn, prompt, opts})
  end

  @doc false
  @spec start_operation(t(), keyword()) :: {:ok, Request.t()} | {:error, term()}
  def start_operation(handle, spec), do: Local.call(handle, {:start_operation, spec})

  @doc false
  @spec await(t(), Request.t(), timeout()) :: term()
  def await(handle, request, timeout \\ :infinity) do
    try do
      with {:ok, server} <- Local.server(handle) do
        GenServer.call(server, {:client_operation, Handle.identity(handle), {:await, request}}, timeout)
      end
    catch
      :exit, {:timeout, _call} -> {:error, :session_await_timeout}
    end
  end

  @doc false
  @spec cancel_and_wait(t(), Request.t(), keyword(), timeout()) :: term()
  def cancel_and_wait(handle, request, opts, timeout \\ :infinity) do
    try do
      with {:ok, server} <- Local.server(handle) do
        GenServer.call(
          server,
          {:client_operation, Handle.identity(handle), {:cancel_wait, request, opts}},
          timeout
        )
      end
    catch
      :exit, {:timeout, _call} -> {:error, :session_cancel_timeout}
    end
  end

  @doc false
  @spec respond_review(t(), :approve | :deny, Request.t(), term(), keyword()) ::
          {:ok, :requested} | {:error, term()}
  def respond_review(handle, decision, request, review, opts \\ []) do
    Local.call(handle, {:respond_review, decision, request, review, opts})
  end

  defp admit(handle, operation, text) when is_binary(text) do
    identity = Handle.identity(handle)

    with {:ok, input} <-
           Input.admit(text,
             session_id: identity.session_id,
             generation: identity.generation,
             owner_instance_id: identity.owner_instance_id
           ) do
      input = Map.put(input, :client_id, identity.client_id)
      driver(handle).input(handle, operation, input)
    end
  end

  defp admit(_handle, _operation, _text), do: {:error, :invalid_input}

  defp driver(handle), do: Handle.driver(handle) || Local
end
