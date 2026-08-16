defmodule Jido.Console.Coding.Local.Setup do
  @moduledoc "Resolved local coding ports and their owned resources."

  alias Jido.Console.Coding.Local.Resources

  @schema Zoi.struct(
            __MODULE__,
            %{
              mutation: Zoi.any(),
              shell: Zoi.any(),
              git: Zoi.any(),
              verify: Zoi.any(),
              disable_tools: Zoi.array(Zoi.string()),
              resources: Zoi.any()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type t :: %__MODULE__{
          mutation: struct(),
          shell: struct(),
          git: struct(),
          verify: struct(),
          disable_tools: [String.t()],
          resources: Resources.t()
        }
end
