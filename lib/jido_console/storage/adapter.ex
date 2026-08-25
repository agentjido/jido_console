defmodule Jido.Console.Storage.Adapter do
  @moduledoc "Contract for a Console session and thread-event storage adapter."

  alias Jido.Console.Session.Event

  @type owner :: term()

  @callback start_link(keyword()) :: GenServer.on_start()
  @callback session_store(owner(), keyword()) :: Jidoka.Session.Store.store()
  @callback append_thread_event(owner(), Event.t(), keyword()) ::
              {:ok, %{event: Event.t(), duplicate: boolean()}} | {:error, term()}
  @callback thread_events(owner(), String.t(), keyword()) ::
              {:ok, %{events: [Event.t()], history_truncated?: boolean()}} | {:error, term()}
  @callback open_thread_items(owner(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback request_events(owner(), String.t(), String.t(), keyword()) ::
              {:ok, [Event.t()]} | {:error, term()}
  @callback inspect_store(owner(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback status(owner(), keyword()) :: {:ok, map()} | {:error, term()}
end
