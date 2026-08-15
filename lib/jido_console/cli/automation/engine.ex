defmodule Jido.Console.Automation.Engine do
  @moduledoc "Runs one planned automation cell."

  @callback run(cell :: map(), opts :: keyword()) :: map()

  @callback start(cell :: map(), opts :: keyword()) :: {:ok, term()} | {:error, term()}
  @callback await(request :: term(), opts :: keyword()) :: map() | {:error, term()}
  @callback cancel(request :: term(), opts :: keyword()) ::
              {:ok, Jidoka.Cancellation.t()} | {:error, term()}

  @optional_callbacks start: 2, await: 2, cancel: 2
end
