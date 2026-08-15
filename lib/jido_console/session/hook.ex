defmodule Jido.Console.Session.Hook do
  @moduledoc """
  Host-independent extension descriptors and hook failure rules.

  This module does not load or host extensions.
  """

  @authority_hooks ~w(authorize approve)
  @info_hooks ~w(observe annotate)

  @doc "Validates one extension descriptor."
  @spec validate(map()) :: {:ok, map()} | {:error, term()}
  def validate(descriptor) when is_map(descriptor) do
    required = ~w(id version capabilities hooks input_schema output_schema provenance trust)

    cond do
      Enum.any?(required, &(not Map.has_key?(descriptor, &1))) ->
        {:error, :incomplete_descriptor}

      Map.get(descriptor, "permission") ->
        {:error, {:unknown_authority_field, ["permission"]}}

      true ->
        {:ok, descriptor}
    end
  end

  def validate(_descriptor), do: {:error, :invalid_descriptor}

  @doc "Applies the declared failure rule without loading an extension."
  @spec fail(String.t(), term()) :: {:error, term()} | {:ok, map()}
  def fail(hook, reason) when hook in @authority_hooks do
    {:error, {:authority_hook_failed, hook, reason}}
  end

  def fail(hook, reason) when hook in @info_hooks do
    {:ok, %{"hook" => hook, "failure" => inspect(reason), "visible" => true}}
  end

  def fail(hook, _reason), do: {:error, {:unknown_hook, hook}}

  @doc "Returns true when this module does not load extensions."
  @spec loads_extensions?() :: false
  def loads_extensions?, do: false
end
