defmodule Jido.Console do
  @moduledoc "Public package entry point for Jido Console."

  @doc "Returns the Jido Console version."
  @spec version() :: String.t()
  def version, do: Jido.Console.Release.Identity.version()

  @doc false
  @spec main([String.t()]) :: :ok
  def main(args), do: Jido.Console.CLI.main(args)

  @doc "Runs one CLI invocation and returns its exit status without halting the VM."
  @spec run([String.t()], keyword()) :: :ok | {:error, pos_integer()}
  def run(args, opts \\ []), do: Jido.Console.CLI.run(args, opts)
end
