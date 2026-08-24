defmodule Jido.Console.Coding.Environment.Contract do
  @moduledoc "Secret-free restricted process environment policy for one coding setup."

  @schema Zoi.struct(
            __MODULE__,
            %{
              execution_policy_id: Zoi.string(),
              allowlist: Zoi.array(Zoi.string()),
              credential_refs: Zoi.array(Zoi.string()),
              home: Zoi.string(),
              tmpdir: Zoi.string()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type t :: %__MODULE__{
          execution_policy_id: String.t(),
          allowlist: [String.t()],
          credential_refs: [String.t()],
          home: String.t(),
          tmpdir: String.t()
        }
end
