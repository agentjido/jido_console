defmodule Jido.Console.Session.SupervisorTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{DynamicSupervisor, Registry, Supervisor}

  defmodule Placeholder do
    use GenServer

    def child_spec(opts) do
      session_id = Keyword.fetch!(opts, :session_id)

      %{
        id: session_id,
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def start_link(opts) do
      session_id = Keyword.fetch!(opts, :session_id)
      registry = Keyword.fetch!(opts, :registry)
      GenServer.start_link(__MODULE__, session_id, name: Registry.via(session_id, registry))
    end

    def init(session_id), do: {:ok, session_id}
  end

  setup do
    suffix = System.unique_integer([:positive])
    supervisor = :"session-sup-#{suffix}"
    registry = :"session-reg-#{suffix}"
    sessions = :"session-dyn-#{suffix}"
    {:ok, pid} = Supervisor.start_link(name: supervisor, registry: registry, sessions: sessions)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)
    %{registry: registry, sessions: sessions, supervisor: supervisor}
  end

  test "starts registry then dynamic supervisor and maps one session ID to one server", %{
    registry: registry,
    sessions: sessions
  } do
    assert Process.whereis(registry)
    assert Process.whereis(sessions)

    opts = [session_id: "ses_one", registry: registry, supervisor: sessions]
    assert {:ok, pid} = DynamicSupervisor.start_session(Placeholder, opts)
    assert {:ok, ^pid} = Registry.lookup("ses_one", registry)
    assert {:error, {:already_started, ^pid}} = DynamicSupervisor.start_session(Placeholder, opts)
    refute is_atom(elem(Registry.via("ses_untrusted", registry), 2) |> elem(1))
    assert is_binary(elem(Registry.via("ses_untrusted", registry), 2) |> elem(1))
  end

  test "normal stop removes the registry entry", %{registry: registry, sessions: sessions} do
    session_id = "ses_stop_#{System.unique_integer([:positive])}"
    opts = [session_id: session_id, registry: registry, supervisor: sessions]
    {:ok, pid} = DynamicSupervisor.start_session(Placeholder, opts)
    ref = Process.monitor(pid)
    :ok = Elixir.DynamicSupervisor.terminate_child(sessions, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    refute Process.alive?(pid)
    assert {:error, :not_found} = Registry.lookup(session_id, registry)
  end

  test "ensure and missing-supervisor paths return stable results", %{supervisor: supervisor} do
    assert {:ok, pid} = Supervisor.ensure_started(name: supervisor)
    assert pid == Process.whereis(supervisor)

    missing_registry = :"missing-registry-#{System.unique_integer([:positive])}"
    missing_sessions = :"missing-sessions-#{System.unique_integer([:positive])}"
    assert {:error, :not_found} = Registry.lookup("missing", missing_registry)

    assert {:error, :not_found} =
             DynamicSupervisor.start_session(Placeholder,
               session_id: "missing",
               registry: missing_registry,
               supervisor: missing_sessions
             )

    suffix = System.unique_integer([:positive])
    name = :"ensured-session-sup-#{suffix}"
    registry = :"ensured-session-reg-#{suffix}"
    sessions = :"ensured-session-dyn-#{suffix}"
    tasks = :"ensured-session-tasks-#{suffix}"

    assert {:ok, ensured} =
             Supervisor.ensure_started(
               name: name,
               registry: registry,
               sessions: sessions,
               tasks: tasks
             )

    on_exit(fn -> if Process.alive?(ensured), do: Process.exit(ensured, :shutdown) end)
    assert Process.whereis(tasks)
    assert {:ok, ^ensured} = Supervisor.ensure_started(name: name)
  end
end
