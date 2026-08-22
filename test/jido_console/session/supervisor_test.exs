defmodule Jido.Console.Session.SupervisorTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.{DynamicSupervisor, Registry, Supervisor}

  defmodule TemporaryOwner do
    use GenServer

    def child_spec(opts) do
      %{
        id: Keyword.fetch!(opts, :thread_id),
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok,
        name: Registry.via(Keyword.fetch!(opts, :thread_id), Keyword.fetch!(opts, :registry))
      )
    end

    def init(:ok), do: {:ok, %{}}
  end

  setup do
    suffix = System.unique_integer([:positive])
    name = unique(:session_supervisor, suffix)
    registry = unique(:registry, suffix)
    sessions = unique(:sessions, suffix)
    tasks = unique(:tasks, suffix)
    {:ok, supervisor} = Supervisor.start_link(name: name, registry: registry, sessions: sessions, tasks: tasks)
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown) end)
    %{supervisor: supervisor, name: name, registry: registry, sessions: sessions, tasks: tasks}
  end

  test "starts Registry, Task.Supervisor, and DynamicSupervisor", context do
    assert is_pid(Process.whereis(context.registry))
    assert is_pid(Process.whereis(context.tasks))
    assert is_pid(Process.whereis(context.sessions))

    opts = [thread_id: "one-thread", registry: context.registry, supervisor: context.sessions]
    assert {:ok, owner} = DynamicSupervisor.start_session(TemporaryOwner, opts)
    assert {:ok, ^owner} = Registry.lookup("one-thread", context.registry)
    assert {:error, {:already_started, ^owner}} = DynamicSupervisor.start_session(TemporaryOwner, opts)
  end

  test "ensure_started starts one named tree and returns the existing tree" do
    suffix = System.unique_integer([:positive])

    opts = [
      name: unique(:ensured_session_supervisor, suffix),
      registry: unique(:ensured_registry, suffix),
      sessions: unique(:ensured_sessions, suffix),
      tasks: unique(:ensured_tasks, suffix)
    ]

    assert {:ok, supervisor} = Supervisor.ensure_started(opts)
    assert {:ok, ^supervisor} = Supervisor.ensure_started(opts)
    assert Process.alive?(supervisor)
    Elixir.Supervisor.stop(supervisor)
  end

  test "default helpers use the application session tree" do
    assert {:ok, supervisor} = Supervisor.ensure_started()
    assert Process.alive?(supervisor)

    assert {:via, Elixir.Registry, {Jido.Console.Session.Registry, "default-thread"}} =
             Registry.via("default-thread")
  end

  test "registry lookup returns not found when the registry does not exist" do
    assert {:error, :not_found} = Registry.lookup("missing-thread", unique(:missing_registry, 0))
  end

  test "ensure_started returns an invalid child configuration error" do
    suffix = System.unique_integer([:positive])
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    assert {:error, {:shutdown, {:failed_to_start_child, 42, _reason}}} =
             Supervisor.ensure_started(
               name: unique(:invalid_session_supervisor, suffix),
               registry: 42,
               sessions: unique(:invalid_sessions, suffix),
               tasks: unique(:invalid_tasks, suffix)
             )
  end

  test "temporary owners are not restarted", context do
    opts = [thread_id: "temporary-thread", registry: context.registry, supervisor: context.sessions]
    {:ok, owner} = DynamicSupervisor.start_session(TemporaryOwner, opts)
    monitor = Process.monitor(owner)
    Process.exit(owner, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :shutdown}
    assert {:error, :not_found} = Registry.lookup("temporary-thread", context.registry)
    assert Elixir.DynamicSupervisor.count_children(context.sessions).active == 0
  end

  test "a task supervisor restart keeps Registry and replaces the dynamic subtree", context do
    registry_pid = Process.whereis(context.registry)
    tasks_pid = Process.whereis(context.tasks)
    sessions_pid = Process.whereis(context.sessions)
    owner_opts = [thread_id: "active-thread", registry: context.registry, supervisor: context.sessions]
    {:ok, owner} = DynamicSupervisor.start_session(TemporaryOwner, owner_opts)
    owner_monitor = Process.monitor(owner)
    tasks_monitor = Process.monitor(tasks_pid)
    sessions_monitor = Process.monitor(sessions_pid)

    Process.exit(tasks_pid, :kill)
    assert_receive {:DOWN, ^tasks_monitor, :process, ^tasks_pid, :killed}
    assert_receive {:DOWN, ^sessions_monitor, :process, ^sessions_pid, :shutdown}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :shutdown}

    assert Process.whereis(context.registry) == registry_pid
    assert_eventually(fn -> is_pid(Process.whereis(context.tasks)) and Process.whereis(context.tasks) != tasks_pid end)

    assert_eventually(fn ->
      is_pid(Process.whereis(context.sessions)) and Process.whereis(context.sessions) != sessions_pid
    end)

    assert {:error, :not_found} = Registry.lookup("active-thread", context.registry)
  end

  defp unique(label, suffix), do: String.to_atom("#{label}-#{suffix}")

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      receive do
      after
        10 -> :ok
      end

      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
