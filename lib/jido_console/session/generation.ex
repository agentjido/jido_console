defmodule Jido.Console.Session.Generation do
  @moduledoc "Process-local owner identity for stale asynchronous messages."

  @max_token_bytes 256

  @type t :: %{
          required(:session_id) => String.t(),
          required(:generation) => pos_integer(),
          required(:owner_instance_id) => String.t(),
          required(:operation_id) => String.t(),
          required(:state) => :active | :released
        }

  @doc "Creates a new process-local session owner."
  @spec claim(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def claim(session_id, opts \\ []) when is_binary(session_id) do
    with :ok <- validate_token(session_id, :session_id),
         {:ok, owner_instance_id} <- option_token(opts, :owner_instance_id, &owner_id/0),
         {:ok, operation_id} <- option_token(opts, :operation_id, fn -> "owner-start" end) do
      {:ok,
       %{
         session_id: session_id,
         generation: System.unique_integer([:positive, :monotonic]),
         owner_instance_id: owner_instance_id,
         operation_id: operation_id,
         state: :active
       }}
    end
  end

  @doc "Marks one process-local owner as released."
  @spec release(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def release(owner, _opts \\ []) do
    with :ok <- validate(owner) do
      {:ok, %{owner | state: :released}}
    end
  end

  @doc "Adds the current operation identity."
  @spec for_operation(t(), String.t()) :: t()
  def for_operation(owner, operation_id) when is_map(owner) and is_binary(operation_id) do
    Map.put(owner, :operation_id, operation_id)
  end

  @doc "Returns true for the same process-local owner."
  @spec same?(t(), t()) :: boolean()
  def same?(left, right) do
    left.session_id == right.session_id and left.generation == right.generation and
      left.owner_instance_id == right.owner_instance_id
  end

  @doc "Returns true for an older or different owner of the same session."
  @spec stale?(t(), t()) :: boolean()
  def stale?(current, candidate) do
    current.session_id == candidate.session_id and
      (candidate.generation < current.generation or
         (candidate.generation == current.generation and
            candidate.owner_instance_id != current.owner_instance_id))
  end

  @doc "Validates one process-local owner identity."
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(owner) when is_map(owner) do
    with :ok <- validate_token(Map.get(owner, :session_id), :session_id),
         generation when is_integer(generation) and generation > 0 <- Map.get(owner, :generation),
         :ok <- validate_token(Map.get(owner, :owner_instance_id), :owner_instance_id),
         :ok <- validate_token(Map.get(owner, :operation_id), :operation_id) do
      :ok
    else
      _other -> {:error, :invalid_generation}
    end
  end

  def validate(_owner), do: {:error, :invalid_generation}

  @doc "Converts one owner identity to portable data."
  @spec to_protocol(t()) :: map()
  def to_protocol(owner) do
    %{
      "session_id" => owner.session_id,
      "generation" => owner.generation,
      "owner_instance_id" => owner.owner_instance_id,
      "operation_id" => owner.operation_id,
      "state" => Atom.to_string(owner.state)
    }
  end

  defp option_token(opts, key, default) do
    value = Keyword.get_lazy(opts, key, default)

    case validate_token(value, key) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_token(value, _field)
       when is_binary(value) and value != "" and byte_size(value) <= @max_token_bytes,
       do: :ok

  defp validate_token(_value, field), do: {:error, {:invalid_generation_token, field}}

  defp owner_id do
    "own-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end
end
