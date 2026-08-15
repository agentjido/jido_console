defmodule Jido.Console.Session.DynamicSupervisor do
  @moduledoc "Dynamic supervisor for one temporary session server per live session."

  use DynamicSupervisor

  @doc "Starts the dynamic session supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Starts a temporary session server."
  @spec start_session(module(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(server, opts) do
    supervisor = Keyword.get(opts, :supervisor, __MODULE__)
    DynamicSupervisor.start_child(supervisor, {server, opts})
  end
end
