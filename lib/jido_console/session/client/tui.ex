defmodule Jido.Console.Session.Client.TUI do
  @moduledoc "Thin TUI adapter for complete Session.View values."

  alias Jido.Console.Session.{Client, View}
  alias Jido.Console.Tui.State

  @doc "Attaches the TUI to one thread."
  @spec attach(String.t(), keyword()) :: {:ok, Client.attach_result()} | {:error, term()}
  def attach(thread_id, opts \\ []), do: Client.attach(thread_id, opts)

  @doc "Detaches the exact TUI attachment."
  @spec detach(Client.t()) :: :ok | {:error, term()}
  def detach(handle), do: Client.detach(handle)

  @doc "Creates a new attachment for the same thread."
  @spec reattach(Client.t(), keyword()) :: {:ok, Client.attach_result()} | {:error, term()}
  def reattach(handle, opts \\ []), do: Client.reattach(handle, opts)

  @doc "Applies one complete semantic View to renderer-local state."
  @spec apply_view(Client.t(), State.t(), View.t()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def apply_view(handle, state, %View{thread_id: thread_id} = view) do
    if Client.thread_id(handle) == thread_id do
      {:ok, State.restore_view(state, view)}
    else
      {:error, :cross_thread_view, state}
    end
  end

  @doc "Returns the product event types in the current bounded View."
  @spec observe(Client.t()) :: [String.t()]
  def observe(handle) do
    case Client.status(handle) do
      {:ok, view} -> Enum.map(view.history, & &1["type"])
      {:error, _reason} -> []
    end
  end
end
