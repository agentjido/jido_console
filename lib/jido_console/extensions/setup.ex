defmodule Jido.Console.Extensions.Setup do
  @moduledoc "Resolved extension registry and its safe trust projection."

  @enforce_keys [:registry, :projection]
  defstruct [:registry, :projection, recover_coding_errors: false]

  @type t :: %__MODULE__{
          registry: map(),
          projection: map(),
          recover_coding_errors: boolean()
        }
end
