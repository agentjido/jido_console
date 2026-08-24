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

  @doc "Submits one TUI prompt."
  @spec submit(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def submit(handle, prompt, opts), do: Client.submit(handle, prompt, opts)

  @doc "Cancels one TUI request."
  @spec cancel(Client.t(), String.t()) :: {:ok, :requested} | {:error, term()}
  def cancel(handle, request_id), do: Client.cancel(handle, request_id)

  @doc "Approves one TUI review."
  @spec approve(Client.t(), String.t(), String.t()) :: {:ok, :requested} | {:error, term()}
  def approve(handle, request_id, review_id), do: Client.approve(handle, request_id, review_id)

  @doc "Denies one TUI review."
  @spec deny(Client.t(), String.t(), String.t()) :: {:ok, :requested} | {:error, term()}
  def deny(handle, request_id, review_id), do: Client.deny(handle, request_id, review_id)

  @doc "Selects one model from a direct TUI command."
  @spec select_model(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def select_model(handle, identity), do: Client.select_model_as(handle, identity, :tui)

  @doc "Selects one agent source from a direct TUI command."
  @spec select_agent(Client.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def select_agent(handle, source), do: Client.select_agent(handle, source)

  @doc "Selects one execution policy from a direct TUI command."
  @spec select_execution_policy(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def select_execution_policy(handle, id, opts \\ []),
    do: Client.select_execution_policy_as(handle, id, :tui, opts)

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
