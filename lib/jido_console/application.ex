defmodule Jido.Console.Application do
  @moduledoc """
  OTP application supervisor for process and session infrastructure.

  The application owns process, durable storage, and session infrastructure for
  its full lifetime. Rest-for-one ordering stops session mutation when durable
  storage is unavailable.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Jido.Console.Process.Supervisor, name: Jido.Console.Process.Supervisor},
      {Jido.Console.Storage.Supervisor, name: Jido.Console.Storage.Supervisor},
      {Jido.Console.Session.Supervisor, name: Jido.Console.Session.Supervisor}
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Jido.Console.Supervisor)
  end
end
