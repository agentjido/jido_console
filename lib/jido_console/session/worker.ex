defmodule Jido.Console.Session.Worker do
  @moduledoc """
  Supervised model and tool workers that run outside the session owner.
  """

  use GenServer, restart: :temporary

  @doc "Starts a worker that returns one identity-bound result to the owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Runs work in a separate process and returns an identity-bound result."
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) do
    owner = self()

    {:ok, pid} =
      GenServer.start(
        __MODULE__,
        owner: owner,
        identity: Keyword.fetch!(opts, :identity),
        fun: Keyword.fetch!(opts, :fun),
        timeout: Keyword.get(opts, :timeout, 5_000)
      )

    ref = Process.monitor(pid)

    receive do
      {:worker_result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:worker_failed, reason}}
    after
      Keyword.get(opts, :timeout, 5_000) ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        drain_worker_result(pid)
        {:error, :worker_timeout}
    end
  end

  @impl true
  def init(opts) do
    send(self(), :run)
    {:ok, opts}
  end

  @impl true
  def handle_info(:run, opts) do
    result = Keyword.fetch!(opts, :fun).()
    send(Keyword.fetch!(opts, :owner), {:worker_result, self(), bind(Keyword.fetch!(opts, :identity), result)})
    {:stop, :normal, opts}
  end

  defp drain_worker_result(pid) do
    receive do
      {:worker_result, ^pid, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp bind(%{} = identity, result) do
    %{
      identity: identity,
      session_id: identity.session_id,
      result: result,
      worker_pid?: false
    }
  end
end
