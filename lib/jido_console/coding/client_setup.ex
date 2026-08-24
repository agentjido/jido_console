defmodule Jido.Console.Coding.ClientSetup do
  @moduledoc "Portable coding context used by attached session clients."

  @schema Zoi.struct(
            __MODULE__,
            %{
              workspace: Zoi.struct(Jidoka.CodingPack.Workspace) |> Zoi.nullable(),
              instructions: Zoi.array(Zoi.map()),
              context: Zoi.map(),
              pack_id: Zoi.string() |> Zoi.nullable() |> Zoi.optional() |> Zoi.default(nil),
              execution_policy_id: Zoi.string() |> Zoi.nullable() |> Zoi.optional() |> Zoi.default(nil),
              await_timeout_ms: Zoi.integer() |> Zoi.positive(),
              turn_opts: Zoi.list(Zoi.tuple({Zoi.atom(), Zoi.any()}))
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type t :: %__MODULE__{
          workspace: Jidoka.CodingPack.Workspace.t() | nil,
          instructions: [map()],
          context: map(),
          pack_id: String.t() | nil,
          execution_policy_id: String.t() | nil,
          await_timeout_ms: pos_integer(),
          turn_opts: keyword()
        }
end
