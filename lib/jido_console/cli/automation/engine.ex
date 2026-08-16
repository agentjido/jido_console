defmodule Jido.Console.Automation.Engine do
  @moduledoc "Starts, awaits, and cancels one planned automation cell."

  @callback start(cell :: map(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
  @callback await(request :: term(), opts :: keyword()) :: map() | {:error, term()}
  @callback cancel(request :: term(), opts :: keyword()) ::
              {:ok, Jidoka.Cancellation.t()} | {:error, term()}

  @doc "Runs one cell synchronously through the asynchronous engine protocol."
  @spec run(module(), map(), keyword()) :: map() | {:error, term()}
  def run(engine, cell, opts) when is_atom(engine) and is_map(cell) and is_list(opts) do
    with {:ok, request} <- engine.start(cell, opts) do
      engine.await(request, opts)
    end
  end
end
