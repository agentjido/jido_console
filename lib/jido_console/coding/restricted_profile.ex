defmodule Jido.Console.Coding.RestrictedProfile do
  @moduledoc "Deprecated compatibility facade for `Jido.Console.ExecutionPolicy`."

  @deprecated "Use Jido.Console.ExecutionPolicy.restricted_id/0"
  @doc "Returns the restricted execution-policy identifier."
  @spec id() :: String.t()
  def id, do: Jido.Console.ExecutionPolicy.restricted_id()

  @deprecated "Use Jido.Console.ExecutionPolicy.environment_allowlist/0"
  @doc "Returns the default restricted process environment allowlist."
  @spec environment_allowlist() :: [String.t()]
  def environment_allowlist, do: Jido.Console.ExecutionPolicy.environment_allowlist()
end
