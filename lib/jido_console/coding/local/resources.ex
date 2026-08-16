defmodule Jido.Console.Coding.Local.Resources do
  @moduledoc "Owned local coding processes and execution binding."

  alias Jido.Console.Coding.Environment.Contract

  @enforce_keys [:manager, :binding, :mutation_state, :environment_contract, :environment_evidence]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          manager: pid(),
          binding: struct(),
          mutation_state: pid(),
          environment_contract: Contract.t(),
          environment_evidence: Jidoka.ExecutionEnvironment.EnforcementEvidence.t()
        }
end
