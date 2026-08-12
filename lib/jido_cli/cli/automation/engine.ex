defmodule Jido.Cli.Automation.Engine do
  @moduledoc "Runs one planned automation cell."

  @callback run(cell :: map(), opts :: keyword()) :: map()
end
