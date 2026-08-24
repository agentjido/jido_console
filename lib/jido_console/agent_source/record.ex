defmodule Jido.Console.AgentSource.Record do
  @moduledoc "Host-owned agent source data and its immutable base specification."

  @schema Zoi.struct(
            __MODULE__,
            %{
              base_spec: Zoi.any(),
              identity: Zoi.any(),
              kind: Zoi.any(),
              format: Zoi.any(),
              byte_size: Zoi.any(),
              digest: Zoi.any(),
              base_spec_digest: Zoi.any(),
              agent_id: Zoi.any(),
              label: Zoi.any()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type source_kind :: :builtin | :file
  @type source_format :: :compiled | :json | :yaml
  @type file_identity :: %{
          required(:path) => Path.t(),
          required(:major_device) => non_neg_integer(),
          required(:minor_device) => non_neg_integer(),
          required(:inode) => non_neg_integer()
        }
  @type t :: %__MODULE__{
          base_spec: Jidoka.Agent.Spec.t(),
          identity: String.t() | file_identity(),
          kind: source_kind(),
          format: source_format(),
          byte_size: non_neg_integer(),
          digest: String.t(),
          base_spec_digest: String.t(),
          agent_id: String.t(),
          label: String.t()
        }

  @doc false
  @spec build(keyword()) :: t()
  def build(fields) when is_list(fields), do: struct!(__MODULE__, fields)
end
