defmodule Jido.Console.ExecutionPolicy.Definition do
  @moduledoc false

  alias Jidoka.ExecutionEnvironment.PolicyRequest

  @restricted_id "coding.restricted"
  @trusted_id "coding.trusted-workspace"
  @trusted_alias "coding.local"
  @trusted_warning "Trusted-workspace mode is not a sandbox."
  @legacy_warning "coding profile is deprecated; use execution policy"
  @environment_allowlist ~w(PATH LANG TERM TMPDIR HOME)

  @doc false
  @spec restricted_id() :: String.t()
  def restricted_id, do: @restricted_id

  @doc false
  @spec trusted_id() :: String.t()
  def trusted_id, do: @trusted_id

  @doc false
  @spec trusted_alias() :: String.t()
  def trusted_alias, do: @trusted_alias

  @doc false
  @spec trusted_warning() :: String.t()
  def trusted_warning, do: @trusted_warning

  @doc false
  @spec legacy_warning() :: String.t()
  def legacy_warning, do: @legacy_warning

  @doc false
  @spec environment_allowlist() :: [String.t()]
  def environment_allowlist, do: @environment_allowlist

  @doc false
  @spec normalize_id(term()) :: term()
  def normalize_id(nil), do: nil

  def normalize_id(id) when is_binary(id) do
    case String.trim(id) do
      @trusted_alias -> @trusted_id
      normalized -> normalized
    end
  end

  def normalize_id(value), do: value

  @doc false
  @spec policy_request(String.t()) :: {:ok, PolicyRequest.t()} | {:error, term()}
  def policy_request(id) when is_binary(id) do
    case normalize_id(id) do
      "" -> {:error, :invalid_agent_execution_policy_request}
      normalized -> PolicyRequest.new(profile_id: normalized)
    end
  end

  def policy_request(_value), do: {:error, :invalid_agent_execution_policy_request}
end
