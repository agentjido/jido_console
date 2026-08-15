defmodule Jido.Console.Coding.Local.Setup do
  @moduledoc "Resolved local coding ports and their owned resources."

  alias Jido.Console.Coding.Local.Resources

  @enforce_keys [:mutation, :shell, :git, :verify, :disable_tools, :resources]
  defstruct [:mutation, :shell, :git, :verify, :disable_tools, :resources]

  @type t :: %__MODULE__{
          mutation: struct(),
          shell: struct(),
          git: struct(),
          verify: struct(),
          disable_tools: [String.t()],
          resources: Resources.t()
        }
end
