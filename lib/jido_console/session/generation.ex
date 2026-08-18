defmodule Jido.Console.Session.Generation do
  @moduledoc """
  Durable authority fence for one session-owner incarnation.

  A fence keeps the Console generation, owner instance, operation, and optional
  Jidoka lease as separate values. Callers must derive a new operation fence
  for each durable mutation. An old fence is never upgraded.
  """

  alias Jido.Console.Storage

  @token_bytes 12
  @max_token_bytes 256

  @type t :: %{
          required(:session_id) => String.t(),
          required(:generation) => pos_integer(),
          required(:owner_instance_id) => String.t(),
          required(:operation_id) => String.t(),
          required(:state) => :active | :released,
          optional(:jidoka_lease_id) => String.t() | nil,
          optional(:claimed_at_ms) => non_neg_integer(),
          optional(:released_at_ms) => non_neg_integer() | nil
        }

  @doc "Claims the exact next durable generation before an owner becomes ready."
  @spec claim(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def claim(session_id, opts \\ []) when is_binary(session_id) do
    with :ok <- validate_token(session_id, :session_id),
         {:ok, current} <- Storage.generation(session_id, opts),
         {:ok, expected} <- expected_generation(opts, current.generation),
         {:ok, owner_instance_id} <- option_token(opts, :owner_instance_id, "own"),
         {:ok, operation_id} <- option_token(opts, :operation_id, "generation-claim"),
         {:ok, claimed} <-
           Storage.claim_generation(
             session_id,
             opts
             |> Keyword.put(:expected_generation, expected)
             |> Keyword.put(:owner_instance_id, owner_instance_id)
             |> Keyword.put(:operation_id, operation_id)
           ) do
      {:ok, from_store(claimed, operation_id)}
    end
  end

  @doc "Releases one exact active generation without making it reusable."
  @spec release(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def release(fence, opts \\ []) when is_map(fence) do
    with :ok <- validate(fence),
         {:ok, operation_id} <- option_token(opts, :operation_id, "generation-release"),
         operation_fence = for_operation(fence, operation_id),
         {:ok, released} <-
           Storage.release_generation(operation_fence, Keyword.put(opts, :operation_id, operation_id)) do
      {:ok, from_store(released, operation_id)}
    end
  end

  @doc "Inspects the durable generation head for one session."
  @spec inspect(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect(session_id, opts \\ []), do: Storage.generation(session_id, opts)

  @doc "Returns the immutable generation transition history."
  @spec audit(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def audit(session_id, opts \\ []), do: Storage.generation_audit(session_id, opts)

  @doc "Derives the exact fence for one mutation operation."
  @spec for_operation(t(), String.t()) :: t()
  def for_operation(fence, operation_id) when is_map(fence) and is_binary(operation_id) do
    Map.put(fence, :operation_id, operation_id)
  end

  @doc "Binds a separate Jidoka lease identity for a later watermark check."
  @spec bind_jidoka_lease(t(), String.t()) :: {:ok, t()} | {:error, term()}
  def bind_jidoka_lease(fence, jidoka_lease_id) when is_map(fence) do
    with :ok <- validate(fence),
         :ok <- validate_token(jidoka_lease_id, :jidoka_lease_id) do
      {:ok, Map.put(fence, :jidoka_lease_id, jidoka_lease_id)}
    end
  end

  @doc "Returns true only for the same owner incarnation."
  @spec same?(t(), t()) :: boolean()
  def same?(left, right) do
    left.session_id == right.session_id and left.generation == right.generation and
      left.owner_instance_id == right.owner_instance_id
  end

  @doc "Returns true for an older generation or another owner at the same generation."
  @spec stale?(t(), t()) :: boolean()
  def stale?(current, candidate) do
    current.session_id == candidate.session_id and
      (candidate.generation < current.generation or
         (candidate.generation == current.generation and
            candidate.owner_instance_id != current.owner_instance_id))
  end

  @doc "Validates the bounded durable fence fields."
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(fence) when is_map(fence) do
    with :ok <- validate_token(Map.get(fence, :session_id), :session_id),
         generation when is_integer(generation) and generation > 0 <- Map.get(fence, :generation),
         :ok <- validate_token(Map.get(fence, :owner_instance_id), :owner_instance_id),
         :ok <- validate_token(Map.get(fence, :operation_id), :operation_id) do
      :ok
    else
      nil -> {:error, :invalid_generation}
      _other -> {:error, :invalid_generation}
    end
  end

  def validate(_fence), do: {:error, :invalid_generation_fence}

  @doc "Returns the protocol-safe generation identity."
  @spec to_protocol(t()) :: map()
  def to_protocol(fence) do
    %{
      "session_id" => fence.session_id,
      "generation" => fence.generation,
      "owner_instance_id" => fence.owner_instance_id,
      "operation_id" => fence.operation_id,
      "jidoka_lease_id" => Map.get(fence, :jidoka_lease_id),
      "state" => Atom.to_string(Map.get(fence, :state, :active))
    }
  end

  defp expected_generation(opts, current) do
    case Keyword.get(opts, :expected_generation, current) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> {:error, :invalid_expected_generation}
    end
  end

  defp option_token(opts, key, prefix) do
    value = Keyword.get_lazy(opts, key, fn -> generate(prefix) end)

    case validate_token(value, key) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  defp validate_token(value, _key)
       when is_binary(value) and value != "" and byte_size(value) <= @max_token_bytes,
       do: :ok

  defp validate_token(_value, key), do: {:error, {:invalid_generation_token, key}}

  defp generate(prefix) do
    token = @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{prefix}-#{token}"
  end

  defp from_store(value, operation_id) do
    value
    |> Map.put(:operation_id, operation_id)
    |> Map.delete(:claim_operation_id)
  end
end
