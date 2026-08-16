defmodule Jido.Console.Application do
  @moduledoc """
  OTP application supervisor for session infrastructure.

  Start order is the session registry, then the dynamic session supervisor.
  """

  use Application

  @impl true
  def start(_type, _args) do
    case Jido.Console.Session.Supervisor.start_link(name: Jido.Console.Session.Supervisor) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end
end
