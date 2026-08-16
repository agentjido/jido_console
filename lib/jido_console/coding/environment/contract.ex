defmodule Jido.Console.Coding.Environment.Contract do
  @moduledoc "Secret-free restricted process environment policy for one coding setup."

  @enforce_keys [:profile_id, :allowlist, :credential_refs, :home, :tmpdir]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          profile_id: String.t(),
          allowlist: [String.t()],
          credential_refs: [String.t()],
          home: String.t(),
          tmpdir: String.t()
        }
end
