defmodule Jido.Console.Session.Identity.Invocation do
  @moduledoc """
  Model-invocation identity for one effective process-lifetime call.

  The identity names provider, model, variant, generation settings, execution
  profile, prompt digest, tool schema digest, skill schema digest, and fallback
  attempt. Credential values are rejected.
  """

  alias Jido.Console.Session.Identity

  @type t :: %{
          required(:identity) => Identity.t(),
          required(:provider) => String.t(),
          required(:model) => String.t(),
          required(:variant) => String.t() | nil,
          required(:generation) => map(),
          required(:profile) => String.t(),
          required(:prompt_digest) => String.t(),
          required(:tool_schema_digest) => String.t(),
          required(:skill_schema_digest) => String.t(),
          required(:fallback_attempt) => non_neg_integer()
        }

  @doc "Builds a model-invocation identity without credential values."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with :ok <- reject_credentials(opts),
         {:ok, identity} <- Identity.new(:invocation, identity_opts(opts)),
         {:ok, provider} <- required_string(opts, :provider),
         {:ok, model} <- required_string(opts, :model) do
      {:ok,
       %{
         identity: identity,
         provider: provider,
         model: model,
         variant: Keyword.get(opts, :variant),
         generation: Map.new(Keyword.get(opts, :generation, [])),
         profile: Keyword.get(opts, :profile, "default"),
         prompt_digest: digest(Keyword.get(opts, :prompt, "")),
         tool_schema_digest: digest(Keyword.get(opts, :tool_schema, %{})),
         skill_schema_digest: digest(Keyword.get(opts, :skill_schema, %{})),
         fallback_attempt: Keyword.get(opts, :fallback_attempt, 0)
       }}
    end
  end

  @doc "Returns a protocol-safe invocation record."
  @spec to_protocol(t()) :: map()
  def to_protocol(invocation) do
    invocation.identity
    |> Identity.to_protocol()
    |> Map.merge(%{
      "provider" => invocation.provider,
      "model" => invocation.model,
      "variant" => invocation.variant,
      "generation" => stringify_keys(invocation.generation),
      "profile" => invocation.profile,
      "prompt_digest" => invocation.prompt_digest,
      "tool_schema_digest" => invocation.tool_schema_digest,
      "skill_schema_digest" => invocation.skill_schema_digest,
      "fallback_attempt" => invocation.fallback_attempt
    })
  end

  defp identity_opts(opts) do
    opts
    |> Keyword.take([:session_id, :id])
    |> Keyword.put(:generation, Keyword.get(opts, :identity_generation, 1))
  end

  defp required_string(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:invocation_field_missing, key}}
    end
  end

  defp reject_credentials(opts) do
    if Enum.any?([:credential, :token, :password, :api_key], &Keyword.has_key?(opts, &1)) do
      {:error, :credential_in_identity}
    else
      :ok
    end
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
