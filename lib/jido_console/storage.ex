defmodule Jido.Console.Storage do
  @moduledoc """
  Bounded public access to the durable Console store.

  A caller must reserve an operation slot and copied payload bytes before the
  request enters the private SQLite writer mailbox. A public timeout reports an
  unknown result with the operation identity; it does not claim a rollback.
  """

  alias Jido.Console.Session.Durable.Record
  alias Jido.Console.Session.Store.SQLite
  alias Jido.Console.Storage.{Admission, Quota}

  @public_deadline 1_000
  @sqlite_page_bytes 4_096
  @sqlite_write_overhead_pages 8

  @doc "Appends one record through the bounded normal write lane."
  @spec append(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def append(record, opts \\ []) when is_map(record) do
    with {:ok, encoded} <- Record.encode(record),
         {:ok, operation_id} <- operation_id(opts),
         :ok <- writer_available(opts),
         high_water = write_high_water(encoded.encoded_bytes),
         {:ok, quota_token} <-
           Quota.reserve(quota(opts), operation_id, :normal_write, :normal, %{
             active_database: high_water,
             wal: high_water
           }) do
      append_admitted(record, encoded, high_water, operation_id, quota_token, opts)
    end
  end

  @doc "Looks up one durable operation result."
  @spec receipt(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def receipt(operation_id, opts \\ []) when is_binary(operation_id) do
    with :ok <- writer_available(opts) do
      SQLite.receipt(writer(opts), operation_id, call_timeout: Keyword.get(opts, :deadline, @public_deadline))
    end
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Reads one ordered record range within the public reader deadline."
  @spec range(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def range(scope_id, opts \\ []) when is_binary(scope_id) do
    with :ok <- writer_available(opts) do
      SQLite.range(writer(opts), scope_id,
        limit: Keyword.get(opts, :limit, 100),
        max_bytes: Keyword.get(opts, :max_bytes, 8 * 1_024 * 1_024),
        after: Keyword.get(opts, :after, -1),
        call_timeout: Keyword.get(opts, :deadline, @public_deadline)
      )
    end
  catch
    :exit, {:timeout, _call} -> {:error, :storage_reader_timeout}
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Runs the store-wide integrity inspection within the public deadline."
  @spec inspect_store(keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_store(opts \\ []) do
    with :ok <- writer_available(opts) do
      SQLite.inspect_store(writer(opts),
        call_timeout: Keyword.get(opts, :deadline, @public_deadline)
      )
    end
  catch
    :exit, {:timeout, _call} -> {:error, :storage_reader_timeout}
    :exit, _reason -> {:error, :storage_unavailable}
  end

  @doc "Returns bounded admission and writer state without exposing the writer PID."
  @spec status(keyword()) :: {:ok, map()} | {:error, term()}
  def status(opts \\ []) do
    with {:ok, admission_status} <- Admission.status(admission(opts)),
         {:ok, quota_status} <- Quota.status(quota(opts)),
         :ok <- writer_available(opts),
         {:ok, pages} <- SQLite.page_accounting(writer(opts), call_timeout: @public_deadline) do
      {:ok, %{admission: admission_status, quota: quota_status, pages: pages, writer: :available}}
    end
  catch
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp operation_id(opts) do
    case Keyword.get(opts, :operation_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :operation_id_required}
    end
  end

  defp writer_available(opts) do
    case GenServer.whereis(writer(opts)) do
      pid when is_pid(pid) -> :ok
      nil -> {:error, :storage_unavailable}
    end
  end

  defp admission(opts), do: Keyword.get(opts, :admission, Jido.Console.Storage.Admission)
  defp quota(opts), do: Keyword.get(opts, :quota, Jido.Console.Storage.Quota)
  defp writer(opts), do: Keyword.get(opts, :writer, Jido.Console.Storage.Writer)

  defp write_high_water(encoded_bytes) do
    encoded_pages = div(encoded_bytes + @sqlite_page_bytes - 1, @sqlite_page_bytes)
    (encoded_pages + @sqlite_write_overhead_pages) * @sqlite_page_bytes
  end

  defp append_admitted(record, encoded, high_water, operation_id, quota_token, opts) do
    case Admission.reserve(admission(opts), :normal, encoded.encoded_bytes,
           page_bytes: high_water,
           wal_bytes: high_water
         ) do
      {:ok, token} ->
        result = call_writer(record, operation_id, token, opts)
        finish_quota(result, quota_token, operation_id, opts)

      {:error, _reason} = error ->
        _result = Quota.finish(quota(opts), quota_token, :rolled_back)
        error
    end
  end

  defp call_writer(record, operation_id, token, opts) do
    try do
      result =
        SQLite.append(writer(opts), record,
          operation_id: operation_id,
          call_timeout: Keyword.get(opts, :deadline, @public_deadline)
        )

      refresh_wal(opts)
      result
    catch
      :exit, {:timeout, _call} ->
        {:error, {:timeout_unknown, operation_id}}

      :exit, {:noproc, _call} ->
        {:error, :storage_unavailable}

      :exit, {:normal, _call} ->
        {:error, :storage_unavailable}
    after
      Admission.release(admission(opts), token)
    end
  end

  defp finish_quota({:error, {:timeout_unknown, operation_id}} = result, _token, operation_id, _opts),
    do: result

  defp finish_quota(result, token, operation_id, opts) do
    outcome = if match?({:ok, _value}, result), do: :committed, else: :rolled_back

    case Quota.finish(quota(opts), token, outcome) do
      {:ok, _quota_result} -> result
      {:error, _reason} -> {:error, {:timeout_unknown, operation_id}}
    end
  end

  defp refresh_wal(opts) do
    case SQLite.checkpoint(writer(opts), call_timeout: 250) do
      {:ok, %{bytes: bytes, checkpoint: checkpoint}} -> Admission.wal(admission(opts), bytes, checkpoint)
      {:error, _reason} -> :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
