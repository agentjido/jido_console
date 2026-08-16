defmodule Jido.Console.Session.Supervisor do
  @moduledoc """
  Supervises the session registry, runtime tasks, and dynamic session
  supervisor.

  This topology is process-lifetime only. It does not recover sessions after
  an application restart.
  """

  use Supervisor

  @doc "Starts the session infrastructure supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Starts the supervisor if it is not already running."
  @spec ensure_started(keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case Process.whereis(name) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case start_link(opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    registry = Keyword.get(opts, :registry, Jido.Console.Session.Registry)
    sessions = Keyword.get(opts, :sessions, Jido.Console.Session.DynamicSupervisor)

    task_children =
      case Keyword.fetch(opts, :tasks) do
        {:ok, tasks} -> [{Task.Supervisor, name: tasks}]
        :error when name == __MODULE__ -> [{Task.Supervisor, name: Jido.Console.Session.TaskSupervisor}]
        :error -> []
      end

    children =
      [{Jido.Console.Session.Registry, name: registry}] ++
        task_children ++ [{Jido.Console.Session.DynamicSupervisor, name: sessions}]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
