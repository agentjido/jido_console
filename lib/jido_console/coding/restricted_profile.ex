defmodule Jido.Console.Coding.RestrictedProfile do
  @moduledoc "Defines the shared identity and environment defaults for restricted coding."

  @id "coding.restricted"
  @environment_allowlist ~w(PATH LANG TERM TMPDIR HOME)

  @doc "Returns the restricted coding profile identifier."
  @spec id() :: String.t()
  def id, do: @id

  @doc "Returns the default restricted process environment allowlist."
  @spec environment_allowlist() :: [String.t()]
  def environment_allowlist, do: @environment_allowlist
end
