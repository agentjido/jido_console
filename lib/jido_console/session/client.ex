defmodule Jido.Console.Session.Client do
  @moduledoc """
  Driver contract for attaching to and controlling a supervised session.
  """

  alias Jido.Console.Session.{
    Cancellation,
    Delivery,
    Drain,
    Effect,
    Hook,
    Identity,
    Input,
    Permission,
    Queue,
    Recovery,
    Result,
    Server
  }

  @type t :: %{
          session: Identity.t(),
          client: Identity.t(),
          server: pid(),
          delivery: Delivery.t()
        }

  @doc "Attaches a client to a live session."
  @spec attach(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def attach(session_id, opts \\ []) do
    with {:ok, server} <- Server.ensure_started(session_id, opts),
         {:ok, client} <- Identity.new(:client, session_id: session_id),
         {:ok, _snapshot} <- Server.attach(server, client) do
      {:ok,
       %{
         session: Identity.new!(:session, id: session_id, session_id: session_id),
         client: client,
         server: server,
         delivery: Delivery.new(client_id: client.id, session_id: session_id)
       }}
    end
  end

  @doc "Detaches the client without stopping the session."
  @spec detach(t()) :: :ok | {:error, term()}
  def detach(handle), do: Server.detach(handle.server, handle.client)

  @doc "Admits process-lifetime input."
  @spec send_input(t(), String.t()) :: {:ok, Input.t()} | {:error, term()}
  def send_input(handle, text), do: Input.admit(text, session_id: handle.session.id)

  @doc "Steers the active run."
  @spec steer(t(), Queue.t(), map()) :: {:ok, Queue.t()} | {:error, term()}
  def steer(_handle, queues, item), do: Queue.add(queues, :steering, item)

  @doc "Queues follow-up input."
  @spec queue(t(), Queue.t(), map()) :: {:ok, Queue.t()} | {:error, term()}
  def queue(_handle, queues, item), do: Queue.add(queues, :follow_up, item)

  @doc "Removes a queued item."
  @spec remove(t(), Queue.t(), atom(), String.t()) :: {:ok, Queue.t()} | {:error, term()}
  def remove(_handle, queues, kind, input_id), do: Queue.remove(queues, kind, input_id)

  @doc "Requests two-stage cancellation."
  @spec cancel(map(), Drain.t()) :: Cancellation.t()
  def cancel(identity, drain), do: Cancellation.request(identity, drain)

  @doc "Approves a pending permission."
  @spec approve(Permission.t(), map()) :: {:ok, Permission.t(), atom()} | {:error, term()}
  def approve(table, response), do: Permission.respond(table, Map.put(response, :decision, :approved))

  @doc "Rejects a pending permission."
  @spec reject(Permission.t(), map()) :: {:ok, Permission.t(), atom()} | {:error, term()}
  def reject(table, response), do: Permission.respond(table, Map.put(response, :decision, :denied))

  @doc "Returns a snapshot of the session."
  @spec snapshot(t()) :: map()
  def snapshot(handle), do: handle.server |> Server.state() |> Jido.Console.Session.Reducer.snapshot()

  @doc "Acknowledges a delivered sequence."
  @spec ack(t(), non_neg_integer()) :: {:ok, Delivery.t()} | {:error, term()}
  def ack(handle, sequence), do: Delivery.ack(handle.delivery, handle.client.id, handle.session.id, sequence)

  @doc "Recovers from an explicit gap."
  @spec recover(t(), [map()]) :: {:ok, Delivery.t(), term()} | {:error, term()}
  def recover(handle, suffix) do
    Recovery.recover(Server.state(handle.server), handle.delivery, suffix)
  end

  @doc "Returns capability names advertised by this contract."
  @spec capabilities() :: [String.t()]
  def capabilities, do: ~w(attach detach input output snapshot control capability ack recover)

  @doc "Wraps a typed effect, result, permission, and hook outcome."
  @spec outcomes(Effect.t(), Result.t(), atom(), map()) :: map()
  def outcomes(effect, result, permission, hook) do
    %{
      effect: Effect.to_protocol(effect),
      result: Result.to_protocol(result),
      permission: permission,
      hook: hook,
      loads_extensions?: Hook.loads_extensions?()
    }
  end
end
