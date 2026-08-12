defmodule Jido.Cli.Runtime do
  @moduledoc "Injectable agent runtime boundary for the TUI."

  @type cancel_result :: {:ok, Jidoka.Cancellation.t()} | {:error, term()}

  @callback start_session(agent :: module(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback start_turn(session :: term(), prompt :: String.t(), owner :: pid(), keyword()) ::
              {:ok, term()} | {:error, term()}
  @callback await(request :: term(), keyword()) :: term()
  @callback cancel(request :: term(), keyword()) :: cancel_result()
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
  def cancel(request, opts), do: Jidoka.cancel(request, opts)
end
