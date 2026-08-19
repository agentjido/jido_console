defmodule Jido.Console.Storage.Supervisor do
  @moduledoc "Owns the home lock and the single SQLite writer."

  use Supervisor

  alias Jido.Console.Storage.{HomeLock, SQLite}

  @doc "Starts storage before session processes."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    common = Keyword.take(opts, [:jido_home, :user_home, :path])
    lock = Keyword.get(opts, :lock, Jido.Console.Storage.HomeLock)
    writer = Keyword.get(opts, :writer, Jido.Console.Storage.Writer)

    children = [
      {HomeLock, common |> Keyword.delete(:path) |> Keyword.put(:name, lock)},
      {SQLite, Keyword.merge(common, name: writer, integrity_on_open: true)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
