defmodule Jido.Console.Storage do
  @moduledoc "Public access to the SQLite session and thread-event store."

  alias Jido.Console.Session.Event
  alias Jido.Console.Storage.SQLite

  @deadline 1_000

  @doc "Returns the configured public Jidoka store reference."
  @spec session_store(keyword()) :: Jidoka.Session.Store.store()
  def session_store(opts \\ []) do
    {SQLite, pid: writer(opts), call_timeout: deadline(opts)}
  end

  @doc "Appends one ordered product-history event."
  @spec append_thread_event(Event.t(), keyword()) ::
          {:ok, %{event: Event.t(), duplicate: boolean()}} | {:error, term()}
  def append_thread_event(%Event{} = event, opts \\ []) do
    write_call(fn -> SQLite.append_thread_event(writer(opts), event, sqlite_opts(opts)) end, event.id)
  end

  @doc "Returns a bounded product-history window."
  @spec thread_events(String.t(), keyword()) ::
          {:ok, %{events: [Event.t()], history_truncated?: boolean()}} | {:error, term()}
  def thread_events(thread_id, opts \\ []) when is_binary(thread_id) do
    read_call(fn -> SQLite.thread_events(writer(opts), thread_id, sqlite_opts(opts)) end)
  end

  @doc "Returns all accepted items that do not have a closing outcome."
  @spec open_thread_items(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def open_thread_items(thread_id, opts \\ []) when is_binary(thread_id) do
    read_call(fn -> SQLite.open_thread_items(writer(opts), thread_id, sqlite_opts(opts)) end)
  end

  @doc "Returns product events for one public Jidoka request ID."
  @spec request_events(String.t(), String.t(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def request_events(thread_id, request_id, opts \\ [])
      when is_binary(thread_id) and is_binary(request_id) do
    read_call(fn -> SQLite.request_events(writer(opts), thread_id, request_id, sqlite_opts(opts)) end)
  end

  @doc "Checks SQLite and all stored values."
  @spec inspect_store(keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_store(opts \\ []), do: read_call(fn -> SQLite.inspect_store(writer(opts), sqlite_opts(opts)) end)

  @doc "Returns small storage counts."
  @spec status(keyword()) :: {:ok, map()} | {:error, term()}
  def status(opts \\ []), do: read_call(fn -> SQLite.status(writer(opts), sqlite_opts(opts)) end)

  defp write_call(fun, operation_id) do
    fun.()
  catch
    :exit, {:timeout, _call} -> {:error, {:timeout_unknown, operation_id}}
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp read_call(fun) do
    fun.()
  catch
    :exit, {:timeout, _call} -> {:error, :storage_reader_timeout}
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp sqlite_opts(opts) do
    Keyword.take(opts, [:before_sequence, :call_timeout, :clock, :limit])
    |> Keyword.put_new(:call_timeout, deadline(opts))
  end

  defp writer(opts), do: Keyword.get(opts, :writer, Jido.Console.Storage.Writer)
  defp deadline(opts), do: Keyword.get(opts, :deadline, @deadline)
end
