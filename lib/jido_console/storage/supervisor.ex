defmodule Jido.Console.Storage.Supervisor do
  @moduledoc "Rest-for-one ownership tree for the writable durable home."

  use Supervisor

  alias Jido.Console.Session.Store.SQLite
  alias Jido.Console.Storage.{Admission, HomeLock, Maintenance, Quota}

  @doc "Starts the storage ownership tree."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Stops the writer and records one crash-safe maintenance operation."
  @spec begin_maintenance(GenServer.server(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def begin_maintenance(supervisor \\ __MODULE__, operation_id, kind, details \\ %{}, opts \\ []) do
    maintenance = Keyword.get(opts, :maintenance, Jido.Console.Storage.Maintenance)

    with :ok <- Supervisor.terminate_child(supervisor, SQLite),
         {:ok, manifest} <- Maintenance.prepare(maintenance, operation_id, kind, details) do
      {:ok, manifest}
    else
      {:error, _reason} = error ->
        _ = restart_writer(supervisor)
        error
    end
  end

  @doc "Completes maintenance and starts the integrity-gated writer again."
  @spec complete_maintenance(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def complete_maintenance(supervisor \\ __MODULE__, operation_id, opts \\ []) do
    maintenance = Keyword.get(opts, :maintenance, Jido.Console.Storage.Maintenance)

    with :ok <- Maintenance.complete(maintenance, operation_id) do
      restart_writer(supervisor)
    end
  end

  @impl true
  def init(opts) do
    common = Keyword.take(opts, [:jido_home, :user_home])
    lock = Keyword.get(opts, :lock, Jido.Console.Storage.HomeLock)
    maintenance = Keyword.get(opts, :maintenance, Jido.Console.Storage.Maintenance)
    quota = Keyword.get(opts, :quota, Jido.Console.Storage.Quota)
    admission = Keyword.get(opts, :admission, Jido.Console.Storage.Admission)
    writer = Keyword.get(opts, :writer, Jido.Console.Storage.Writer)

    children = [
      {HomeLock, Keyword.put(common, :name, lock)},
      {Maintenance, common |> Keyword.put(:name, maintenance) |> Keyword.put(:writer, writer)},
      {Quota, Keyword.put(common, :name, quota)},
      {Admission, [name: admission]},
      {SQLite, Keyword.merge(common, name: writer, integrity_on_open: true, admission: admission)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp restart_writer(supervisor) do
    case Supervisor.restart_child(supervisor, SQLite) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, reason} -> {:error, {:storage_writer_restart_failed, reason}}
    end
  end
end
