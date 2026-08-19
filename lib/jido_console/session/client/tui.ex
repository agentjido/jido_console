defmodule Jido.Console.Session.Client.TUI do
  @moduledoc "Direct session event adapter for the production TUI."

  alias Jido.Console.Session.Client
  alias Jido.Console.Session.Client.Handle
  alias Jido.Console.Tui.State

  @doc "Attaches the TUI and returns its handle and complete event history."
  @spec attach(String.t(), keyword()) :: {:ok, Client.attach_result()} | {:error, term()}
  def attach(session_id, opts \\ []), do: Client.attach(session_id, opts)

  @doc "Detaches the exact TUI attachment while session work continues."
  @spec detach(Client.t()) :: :ok | {:error, term()}
  def detach(handle), do: Client.detach(handle)

  @doc "Creates a new attachment for the same client and session."
  @spec reattach(Client.t(), keyword()) :: {:ok, Client.attach_result()} | {:error, term()}
  def reattach(handle, opts \\ []) do
    identity = Handle.identity(handle)
    _result = Client.detach(handle)
    Client.attach(identity.session_id, Keyword.put(opts, :client_id, identity.client_id))
  end

  @doc "Applies one direct session event to renderer state."
  @spec apply_event(Client.t(), State.t(), map()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def apply_event(handle, state, event) do
    identity = Handle.identity(handle)

    with true <- event["session_id"] == identity.session_id,
         {:ok, state} <- State.apply_session_event(state, event) do
      {:ok, state}
    else
      false -> {:error, :cross_session_event, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc "Rebuilds renderer state from the complete session event history."
  @spec replay(Client.t(), State.t(), term()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def replay(handle, state, active_request \\ nil) do
    case Client.events(handle) do
      {:ok, events} -> {:ok, State.restore_events(state, events, active_request)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc "Returns ordered event types visible to the TUI."
  @spec observe(Client.t()) :: [String.t()]
  def observe(handle) do
    case Client.events(handle) do
      {:ok, events} -> Enum.map(events, & &1["type"])
      {:error, _reason} -> []
    end
  end
end
