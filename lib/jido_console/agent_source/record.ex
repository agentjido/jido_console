defmodule Jido.Console.AgentSource.Record do
  @moduledoc "Host-owned agent source data and its immutable base specification."

  @enforce_keys [
    :base_spec,
    :identity,
    :kind,
    :format,
    :byte_size,
    :digest,
    :base_spec_digest,
    :agent_id,
    :label
  ]
  defstruct @enforce_keys

  @type source_kind :: :builtin | :file
  @type source_format :: :compiled | :json | :yaml
  @type file_identity :: %{
          required(:path) => Path.t(),
          required(:major_device) => non_neg_integer(),
          required(:minor_device) => non_neg_integer(),
          required(:inode) => non_neg_integer()
        }
  @opaque t :: %__MODULE__{
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
