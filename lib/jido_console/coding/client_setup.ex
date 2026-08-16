defmodule Jido.Console.Coding.ClientSetup do
  @moduledoc "Portable coding context used by attached session clients."

  @enforce_keys [:workspace, :instructions, :context, :await_timeout_ms, :turn_opts]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          workspace: Jidoka.CodingPack.Workspace.t() | nil,
          instructions: [map()],
          context: map(),
          await_timeout_ms: pos_integer(),
          turn_opts: keyword()
        }
end
