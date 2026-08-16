defmodule Jido.Console.Application do
  @moduledoc """
  OTP application supervisor for process and session infrastructure.

  The application owns the process manager and the session supervisor for its
  full lifetime.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Jido.Console.Process.Supervisor, name: Jido.Console.Process.Supervisor},
      {Jido.Console.Session.Supervisor, name: Jido.Console.Session.Supervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Jido.Console.Supervisor)
  end
end
