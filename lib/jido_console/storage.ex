defmodule Jido.Console.Storage do
  @moduledoc """
  Public access to adapter-based session and thread-event storage.

  `Jido.Console.Storage.SQLite` is the default adapter. Set `:adapter` in the
  `:storage_options` application configuration or pass it in the call options
  to use a module that implements `Jido.Console.Storage.Adapter`.
  """

  alias Jido.Console.Session.Event
  alias Jido.Console.Storage.SQLite
  alias Jidoka.Session.Data

  @deadline 1_000

  @doc "Returns the selected storage adapter."
  @spec adapter(keyword()) :: module()
  def adapter(opts \\ []) when is_list(opts) do
    opts
    |> options()
    |> Keyword.get(:adapter, SQLite)
  end

  @doc "Returns the configured public Jidoka store reference."
  @spec session_store(keyword()) :: Jidoka.Session.Store.store()
  def session_store(opts \\ []) do
    {adapter, owner, adapter_opts} = resolve(opts)
    adapter.session_store(owner, adapter_opts)
  end

  @doc "Appends one ordered product-history event."
  @spec append_thread_event(Event.t(), keyword()) ::
          {:ok, %{event: Event.t(), duplicate: boolean()}} | {:error, term()}
  def append_thread_event(%Event{} = event, opts \\ []) do
    {adapter, owner, adapter_opts} = resolve(opts)
    write_call(fn -> adapter.append_thread_event(owner, event, adapter_opts) end, event.id)
  end

  @doc "Replaces one unlocked binding draft with compare-and-set checks."
  @spec put_binding_draft(Data.t(), non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def put_binding_draft(%Data{} = session, expected_revision, expected_generation, opts \\ []) do
    operation_id = "#{session.session_id}:binding-draft:#{expected_generation + 1}"

    write_call(
      fn ->
        SQLite.put_binding_draft(
          writer(opts),
          session,
          expected_revision,
          expected_generation,
          sqlite_opts(opts)
        )
      end,
      operation_id
    )
  end

  @doc "Adopts a binding draft for one fully unused legacy session."
  @spec adopt_binding_draft(Data.t(), non_neg_integer(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def adopt_binding_draft(%Data{} = session, expected_revision, opts \\ []) do
    operation_id = "#{session.session_id}:binding-adopt"

    write_call(
      fn ->
        SQLite.adopt_binding_draft(writer(opts), session, expected_revision, sqlite_opts(opts))
      end,
      operation_id
    )
  end

  @doc "Commits the locked binding and first queued prompt in one transaction."
  @spec lock_first_prompt(Data.t(), Event.t(), String.t(), non_neg_integer(), non_neg_integer(), keyword()) ::
          {:ok, %{session: Data.t(), event: Event.t(), duplicate: boolean()}} | {:error, term()}
  def lock_first_prompt(
        %Data{} = session,
        %Event{} = event,
        operation_id,
        expected_revision,
        expected_generation,
        opts \\ []
      )
      when is_binary(operation_id) do
    uncertain_write_call(
      fn ->
        SQLite.lock_first_prompt(
          writer(opts),
          session,
          event,
          operation_id,
          expected_revision,
          expected_generation,
          sqlite_opts(opts)
        )
      end,
      operation_id
    )
  end

  @doc "Installs a verified runtime spec without changing locked binding evidence."
  @spec install_runtime_spec(Data.t(), String.t(), String.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def install_runtime_spec(%Data{} = session, binding_digest, runtime_fingerprint, opts \\ []) do
    operation_id = "#{session.session_id}:runtime-install:#{binding_digest}"

    write_call(
      fn ->
        SQLite.install_runtime_spec(
          writer(opts),
          session,
          binding_digest,
          runtime_fingerprint,
          sqlite_opts(opts)
        )
      end,
      operation_id
    )
  end

  @doc "Returns a bounded product-history window."
  @spec thread_events(String.t(), keyword()) ::
          {:ok, %{events: [Event.t()], history_truncated?: boolean()}} | {:error, term()}
  def thread_events(thread_id, opts \\ []) when is_binary(thread_id) do
    {adapter, owner, adapter_opts} = resolve(opts)
    read_call(fn -> adapter.thread_events(owner, thread_id, adapter_opts) end)
  end

  @doc "Returns all accepted items that do not have a closing outcome."
  @spec open_thread_items(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def open_thread_items(thread_id, opts \\ []) when is_binary(thread_id) do
    {adapter, owner, adapter_opts} = resolve(opts)
    read_call(fn -> adapter.open_thread_items(owner, thread_id, adapter_opts) end)
  end

  @doc "Returns product events for one public Jidoka request ID."
  @spec request_events(String.t(), String.t(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def request_events(thread_id, request_id, opts \\ [])
      when is_binary(thread_id) and is_binary(request_id) do
    {adapter, owner, adapter_opts} = resolve(opts)
    read_call(fn -> adapter.request_events(owner, thread_id, request_id, adapter_opts) end)
  end

  @doc "Checks the adapter and all stored values."
  @spec inspect_store(keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_store(opts \\ []) do
    {adapter, owner, adapter_opts} = resolve(opts)
    read_call(fn -> adapter.inspect_store(owner, adapter_opts) end)
  end

  @doc "Returns small storage counts."
  @spec status(keyword()) :: {:ok, map()} | {:error, term()}
  def status(opts \\ []) do
    {adapter, owner, adapter_opts} = resolve(opts)
    read_call(fn -> adapter.status(owner, adapter_opts) end)
  end

  defp resolve(opts) do
    opts = options(opts)
    adapter = Keyword.get(opts, :adapter, SQLite)
    owner = Keyword.get(opts, :writer, Jido.Console.Storage.Writer)

    adapter_opts =
      opts
      |> Keyword.delete(:adapter)
      |> Keyword.put_new(:call_timeout, Keyword.get(opts, :deadline, @deadline))

    {adapter, owner, adapter_opts}
  end

  defp options(opts) do
    configured = Application.get_env(:jido_console, :storage_options, [])
    Keyword.merge(configured, opts)
  end

  defp write_call(fun, operation_id) do
    fun.()
  catch
    :exit, {:timeout, _call} -> {:error, {:timeout_unknown, operation_id}}
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp uncertain_write_call(fun, operation_id) do
    fun.()
  catch
    :exit, _reason -> {:error, {:write_unknown, operation_id}}
  end

  defp read_call(fun) do
    fun.()
  catch
    :exit, {:timeout, _call} -> {:error, :storage_reader_timeout}
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp sqlite_opts(opts) do
    Keyword.take(opts, [:before_sequence, :call_timeout, :clock, :failure_stage, :limit])
    |> Keyword.put_new(:call_timeout, deadline(opts))
  end

  defp writer(opts), do: Keyword.get(opts, :writer, Jido.Console.Storage.Writer)
  defp deadline(opts), do: Keyword.get(opts, :deadline, @deadline)
end
