defmodule Jido.Console.Version do
  @moduledoc false

  @compiled Mix.Project.config() |> Keyword.fetch!(:version)

  @doc false
  @spec current() :: String.t()
  def current, do: @compiled
end
