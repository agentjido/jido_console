defmodule Jido.Console.Session.Client do
  @moduledoc """
  Driver contract for attaching to and controlling a supervised session.
  """

  alias Jido.Console.Session.{
    Delivery,
    Identity,
    Input,
    Request,
    Server
  }

  @type t :: %{
          session: Identity.t(),
          client: Identity.t(),
          server: pid(),
          snapshot: map()
        }

  @doc "Attaches a client to a live session."
  @spec attach(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def attach(session_id, opts \\ []) do
    with {:ok, server} <- Server.ensure_started(session_id, opts),
         {:ok, client} <- Identity.new(:client, session_id: session_id),
         {:ok, snapshot} <- Server.attach(server, client) do
      {:ok,
       %{
         session: Identity.new!(:session, id: session_id, session_id: session_id),
         client: client,
         server: server,
         snapshot: snapshot
       }}
    end
  end

  @doc "Detaches the client without stopping the session."
  @spec detach(t()) :: :ok | {:error, term()}
  def detach(handle), do: Server.detach(handle.server, handle.client)

  @doc "Queues a detach without waiting for a busy session owner."
  @spec detach_async(t()) :: :ok
  def detach_async(handle), do: Server.detach_async(handle.server, handle.client)

  @doc "Admits process-lifetime input."
  @spec send_input(t(), String.t()) :: {:ok, Input.t()} | {:error, term()}
  def send_input(handle, text) do
    with {:ok, input} <- Input.admit(text, session_id: handle.session.id) do
      Server.admit_input(handle.server, input)
    end
  end

  @doc "Configures the runtime that is owned by this supervised session."
  @spec configure_runtime(t(), module(), module() | term(), keyword()) :: :ok | {:error, term()}
  def configure_runtime(handle, runtime, agent, opts \\ []) do
    Server.configure_runtime(handle.server, handle.client.id, runtime, agent, opts)
  end

  @doc "Returns bounded information about the session-owned runtime."
  @spec runtime_info(t()) :: {:ok, map()} | {:error, term()}
  def runtime_info(handle), do: Server.runtime_info(handle.server, handle.client.id)

  @doc "Starts one runtime turn under the supervised session owner."
  @spec start_turn(t(), String.t(), keyword()) :: {:ok, Request.t()} | {:error, term()}
  def start_turn(handle, prompt, opts \\ []) do
    with {:ok, _input} <- send_input(handle, prompt) do
      Server.start_turn(handle.server, handle.client.id, prompt, opts)
    end
  end

  @doc "Starts one caller-defined operation under the supervised session owner."
  @spec start_operation(t(), keyword()) :: {:ok, Request.t()} | {:error, term()}
  def start_operation(handle, spec) when is_list(spec) do
    Server.start_operation(handle.server, handle.client.id, spec)
  end

  @doc "Waits for a session-owned request without receiving the raw runtime handle."
  @spec await(t(), Request.t(), timeout()) :: term()
  def await(handle, request, timeout \\ :infinity) do
    Server.await_request(handle.server, request, timeout)
  end

  @doc "Requests cancellation of session-owned work."
  @spec cancel(t(), Request.t(), keyword()) :: {:ok, :requested} | {:error, term()}
  def cancel(handle, request, opts) do
    Server.cancel_request(handle.server, handle.client.id, request, opts)
  end

  @doc "Requests cancellation and waits for the runtime result."
  @spec cancel_and_wait(t(), Request.t(), keyword(), timeout()) :: term()
  def cancel_and_wait(handle, request, opts, timeout \\ :infinity) do
    Server.cancel_request_wait(handle.server, handle.client.id, request, opts, timeout)
  end

  @doc "Responds to a runtime review through the session owner."
  @spec respond_review(t(), :approve | :deny, Request.t(), term(), keyword()) ::
          {:ok, :requested} | {:error, term()}
  def respond_review(handle, decision, request, review, opts \\ []) do
    Server.respond_review(handle.server, handle.client.id, decision, request, review, opts)
  end

  @doc "Returns a snapshot of the session."
  @spec snapshot(t()) :: map()
  def snapshot(handle), do: handle.server |> Server.state() |> Jido.Console.Session.Reducer.snapshot()

  @doc "Acknowledges a delivered sequence."
  @spec ack(t(), non_neg_integer()) :: {:ok, Delivery.t()} | {:error, term()}
  def ack(handle, sequence) do
    Server.ack(handle.server, handle.client.id, handle.session.id, sequence)
  end

  @doc "Recovers from an explicit gap."
  @spec recover(t()) :: {:ok, Delivery.t(), term()} | {:error, term()}
  def recover(handle) do
    Server.recover(handle.server, handle.client.id)
  end

  @doc "Returns capability names advertised by this contract."
  @spec capabilities() :: [String.t()]
  def capabilities, do: ~w(attach detach input output snapshot control capability ack recover)
end
