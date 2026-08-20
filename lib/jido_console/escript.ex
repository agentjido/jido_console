defmodule Jido.Console.Escript do
  @moduledoc false

  @doc false
  @spec main([String.t()]) :: no_return()
  def main(args) do
    Jido.Console.main(args)
    System.halt(0)
  end
end
