defmodule Jido.Cli.Coding.Local.Resources do
  @moduledoc "Owned local coding processes and execution binding."

  @enforce_keys [:manager, :binding, :mutation_state]
  defstruct [:manager, :binding, :mutation_state]

  @type t :: %__MODULE__{manager: pid(), binding: struct(), mutation_state: pid()}
end
