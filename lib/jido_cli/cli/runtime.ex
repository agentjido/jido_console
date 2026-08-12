defmodule Jido.Cli.Runtime do
  @moduledoc "Injectable agent runtime boundary for the TUI."

  @callback start_session(agent :: module(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback start_turn(session :: term(), prompt :: String.t(), owner :: pid(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback await(request :: term(), keyword()) :: term()
  @callback cancel(request :: term(), keyword()) :: {:ok, term()} | {:error, term()}
end

defmodule Jido.Cli.Runtime.Jidoka do
  @moduledoc false

  @behaviour Jido.Cli.Runtime

  @impl Jido.Cli.Runtime
  def start_session(agent, opts), do: Jidoka.session(agent, opts)

  @impl Jido.Cli.Runtime
  def start_turn(session, prompt, owner, opts) do
    opts = opts |> Keyword.put(:stream, true) |> Keyword.put(:stream_to, owner)
    Jidoka.chat_async(session, prompt, opts)
  end

  @impl Jido.Cli.Runtime
  def await(request, opts), do: Jidoka.await(request, opts)

  @impl Jido.Cli.Runtime
  def cancel(%Jidoka.Chat.Request{task: %Task{} = task}, opts) do
    shutdown = Keyword.get(opts, :shutdown, :brutal_kill)

    case Task.shutdown(task, shutdown) do
      nil -> {:ok, :cancelled}
      result -> {:ok, result}
    end
  rescue
    exception -> {:error, exception}
  end
end
