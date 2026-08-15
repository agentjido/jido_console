defmodule Jido.Console.Process do
  @moduledoc """
  Local background-process contracts for Jido Console.

  Each process that can outlive one restricted command has one owner, status,
  readiness, failure, and shutdown path. User-facing status never includes OS
  process identifiers or credential values.
  """

  alias Jido.Console.Process.{Store, Supervisor}

  @statuses [:starting, :ready, :running, :stopping, :stopped, :failed]
  @catalog %{
    interactive: %{
      name: "interactive",
      owner: "tui",
      purpose: "interactive terminal session",
      readiness: "terminal and runtime are ready",
      shutdown: "TUI shutdown through the process supervisor"
    },
    coding_runtime: %{
      name: "coding-runtime",
      owner: "coding",
      purpose: "trusted local coding manager",
      readiness: "execution manager is open",
      shutdown: "coding setup close through the process supervisor"
    }
  }

  @type status :: :starting | :ready | :running | :stopping | :stopped | :failed
  @type kind :: :interactive | :coding_runtime
  @type process_record :: %{
          required(:id) => String.t(),
          required(:kind) => kind(),
          required(:name) => String.t(),
          required(:owner) => String.t(),
          required(:status) => status(),
          required(:readiness) => String.t(),
          optional(:failure) => String.t() | nil
        }

  @doc "Returns the supported process status values."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Returns the local process ownership and status matrix."
  @spec catalog() :: %{kind() => map()}
  def catalog, do: @catalog

  @doc "Returns one catalog entry."
  @spec spec(kind()) :: map()
  def spec(kind) when is_map_key(@catalog, kind), do: Map.fetch!(@catalog, kind)

  @doc "Lists user-facing process records from the isolated home store."
  @spec list(keyword()) :: {:ok, [process_record()]} | {:error, term()}
  def list(opts \\ []) do
    with {:ok, _reaped} <- Store.reap(opts),
         {:ok, records} <- Store.list(opts) do
      {:ok, Enum.map(records, &public_record/1)}
    end
  end

  @doc "Registers one owned process and writes its home marker."
  @spec register(kind(), pid(), keyword()) :: {:ok, process_record()} | {:error, term()}
  def register(kind, pid, opts \\ []) when is_pid(pid) do
    Supervisor.register(kind, pid, opts)
  end

  @doc "Stops one named process. Repeated stops report that it is already stopped."
  @spec stop(String.t(), keyword()) :: {:ok, process_record()} | {:error, term()}
  def stop(name, opts \\ []) when is_binary(name) do
    Supervisor.stop_named(name, opts)
  end

  @doc "Stops every owned process and removes confirmed home markers."
  @spec stop_all(keyword()) :: {:ok, [process_record()]} | {:error, term()}
  def stop_all(opts \\ []) do
    Supervisor.stop_all(opts)
  end

  @doc "Removes stale active markers whose owners are no longer alive."
  @spec reap(keyword()) :: {:ok, [process_record()]} | {:error, term()}
  def reap(opts \\ []) do
    with {:ok, records} <- Store.reap(opts) do
      {:ok, Enum.map(records, &public_record/1)}
    end
  end

  @doc "Formats status records for `jido status` without private identifiers."
  @spec format_status([process_record()]) :: String.t()
  def format_status([]) do
    "jido: no owned background processes\n"
  end

  def format_status(records) do
    header = "NAME\tSTATUS\tOWNER\tREADINESS\n"

    rows =
      Enum.map_join(records, "", fn record ->
        "#{record.name}\t#{record.status}\t#{record.owner}\t#{record.readiness}\n"
      end)

    header <> rows
  end

  @doc "Formats a shutdown result for `jido stop`."
  @spec format_stop(process_record()) :: String.t()
  def format_stop(%{status: :stopped, name: name}), do: "jido: stopped #{name}\n"
  def format_stop(%{status: status, name: name}), do: "jido: #{name} is #{status}\n"

  defp public_record(record) do
    Map.take(record, [:id, :kind, :name, :owner, :status, :readiness, :failure])
  end
end
