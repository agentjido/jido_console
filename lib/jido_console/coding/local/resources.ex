defmodule Jido.Console.Coding.Local.Resources do
  @moduledoc "Owned local coding processes and execution binding."

  alias Jido.Console.Coding.Environment.Contract

  @schema Zoi.struct(
            __MODULE__,
            %{
              manager: Zoi.pid(),
              binding: Zoi.any(),
              mutation_state: Zoi.pid(),
              environment_contract: Zoi.any(),
              environment_evidence: Zoi.struct(Jidoka.ExecutionEnvironment.EnforcementEvidence)
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type t :: %__MODULE__{
          manager: pid(),
          binding: struct(),
          mutation_state: pid(),
          environment_contract: Contract.t(),
          environment_evidence: Jidoka.ExecutionEnvironment.EnforcementEvidence.t()
        }
end
