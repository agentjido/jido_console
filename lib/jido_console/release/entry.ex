defmodule Jido.Console.Release.Entry do
  @moduledoc false

  alias Jido.Console.Release.Probe

  @doc false
  @spec main() :: no_return()
  def main do
    args = Enum.map(:init.get_plain_arguments(), &List.to_string/1)
    System.halt(run(args))
  end

  @doc false
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(args, opts \\ []) when is_list(args) and is_list(opts) do
    if Probe.configured?(opts) do
      Probe.run(args, Keyword.put_new(opts, :cli_run, &Jido.Console.run/2))
    else
      Keyword.get(opts, :cli_main, &Jido.Console.main/1).(args)
      0
    end
  end
end
