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
    opts = [session_id: "ses_stop", registry: registry, supervisor: sessions]
    {:ok, pid} = DynamicSupervisor.start_session(Placeholder, opts)
    ref = Process.monitor(pid)
    :ok = Elixir.DynamicSupervisor.terminate_child(sessions, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    assert {:error, :not_found} = Registry.lookup("ses_stop", registry)
  end
end
