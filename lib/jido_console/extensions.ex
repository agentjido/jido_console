defmodule Jido.Console.Extensions do
  @moduledoc "Public trusted-extension facade for resolution and host lifecycle."

  alias Jido.Console.Extensions.{Host, Resolver, Setup}
  alias Jidoka.Extension.Request

  @doc "Resolves inert requests to a private registry and portable trust projection."
  @spec resolve([Request.t()], keyword()) :: {:ok, Setup.t()} | {:error, term()}
  defdelegate resolve(requests, opts), to: Resolver

  @doc "Opens one public Jidoka host and compiles its operation sources."
  @spec open(Jidoka.Session.Data.t(), [Request.t()], Setup.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def open(session, requests, setup, opts \\ []),
    do: Host.open(session, requests, setup, opts)

  @doc "Returns namespaced extension results and UI data."
  defdelegate results(host), to: Host

  @doc "Closes one host."
  defdelegate close(host), to: Host

  @doc "Returns the long-lived processes owned by one host."
  defdelegate owned_processes(host), to: Host
end
