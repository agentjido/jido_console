defmodule Jido.Console.ExecutionPolicy.Consent do
  @moduledoc false

  @type direct_origin :: :cli | :api | :tui

  @type t :: %__MODULE__{
          execution_policy_id: String.t() | nil,
          origin: direct_origin() | :stored | atom() | nil,
          legacy?: boolean(),
          thread_id: String.t() | nil,
          evidence_digest: String.t() | nil,
          seal: term()
        }

  @schema Zoi.struct(
            __MODULE__,
            %{
              execution_policy_id: Zoi.any() |> Zoi.default(nil),
              origin: Zoi.any() |> Zoi.default(nil),
              legacy?: Zoi.boolean() |> Zoi.default(false),
              thread_id: Zoi.any() |> Zoi.default(nil),
              evidence_digest: Zoi.any() |> Zoi.default(nil),
              seal: Zoi.any() |> Zoi.default(nil)
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @direct_origins [:cli, :api, :tui]
  @seal {__MODULE__, :consent, 1}

  @doc false
  @spec direct(String.t(), direct_origin(), boolean()) :: t()
  def direct(id, origin, legacy?)
      when is_binary(id) and origin in @direct_origins and is_boolean(legacy?) do
    %__MODULE__{
      execution_policy_id: id,
      origin: origin,
      legacy?: legacy?,
      seal: @seal
    }
  end

  @doc false
  @spec stored(String.t(), String.t(), String.t()) :: t()
  def stored(id, thread_id, evidence_digest)
      when is_binary(id) and is_binary(thread_id) and is_binary(evidence_digest) do
    %__MODULE__{
      execution_policy_id: id,
      origin: :stored,
      thread_id: thread_id,
      evidence_digest: evidence_digest,
      seal: @seal
    }
  end

  @doc false
  @spec valid_direct?(term()) :: boolean()
  def valid_direct?(%__MODULE__{
        execution_policy_id: id,
        origin: origin,
        thread_id: nil,
        evidence_digest: nil,
        seal: @seal
      })
      when is_binary(id) and origin in @direct_origins,
      do: true

  def valid_direct?(_value), do: false

  @doc false
  @spec valid_stored?(term()) :: boolean()
  def valid_stored?(%__MODULE__{
        execution_policy_id: id,
        origin: :stored,
        thread_id: thread_id,
        evidence_digest: digest,
        seal: @seal
      })
      when is_binary(id) and is_binary(thread_id) and is_binary(digest),
      do: true

  def valid_stored?(_value), do: false
end
