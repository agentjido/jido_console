defmodule Jido.Console do
  @moduledoc "Public package entry point for Jido Console."

  @doc "Returns the Jido Console version."
  @spec version() :: String.t()
  def version, do: Jido.Console.Version.current()

  @doc false
  @spec main() :: no_return()
  def main do
    args = Enum.map(:init.get_plain_arguments(), &List.to_string/1)
    main(args)
    System.halt(0)
  end

  @doc false
  @spec main([String.t()]) :: :ok
  def main(args), do: Jido.Console.CLI.main(args)

  @doc "Runs one CLI invocation and returns its exit status without halting the VM."
  @spec run([String.t()], keyword()) :: :ok | {:error, pos_integer()}
  def run(args, opts \\ []), do: Jido.Console.CLI.run(args, opts)

  @doc "Opens one interactive thread with validated agent and execution-policy inputs."
  @spec attach(String.t(), keyword()) ::
          {:ok, Jido.Console.Session.Client.attach_result()} | {:error, map()}
  def attach(thread_id, opts \\ []) do
    case Jido.Console.Session.Client.attach(thread_id, opts) do
      {:ok, _attached} = result -> result
      {:error, reason} -> {:error, Jido.Console.SafeDisplay.to_map(reason)}
    end
  end
end
