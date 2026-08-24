defmodule Jido.Console.Session.BindingRequest do
  @moduledoc "Explicit binding choices sent to the thread owner during attach."

  alias Jido.Console.ExecutionPolicy

  @schema Zoi.struct(
            __MODULE__,
            %{
              agent_source: Zoi.any(),
              coding_pack: Zoi.any(),
              model: Zoi.any(),
              execution_policy: Zoi.any(),
              project_root: Zoi.any()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type t :: %__MODULE__{
          agent_source: term(),
          coding_pack: term(),
          model: String.t() | nil,
          execution_policy: String.t() | nil,
          project_root: Path.t() | nil
        }

  @doc "Keeps only explicit product choices and drops infrastructure options."
  @spec from_options(keyword()) :: {:ok, t()} | {:error, term()}
  def from_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, policy} <- policy(opts),
           {:ok, model} <- optional_string(explicit(opts, :model)),
           {:ok, project_root} <- optional_string(explicit(opts, :project_root)) do
        {:ok,
         %__MODULE__{
           agent_source: agent_source(opts),
           coding_pack: explicit(opts, :coding_pack),
           model: model,
           execution_policy: policy,
           project_root: project_root
         }}
      end
    else
      {:error, :invalid_binding_request_options}
    end
  end

  def from_options(_opts), do: {:error, :invalid_binding_request_options}

  @doc "Returns true when the caller supplied at least one binding choice."
  @spec explicit?(t()) :: boolean()
  def explicit?(%__MODULE__{} = request) do
    Enum.any?(
      [
        request.agent_source,
        request.coding_pack,
        request.model,
        request.execution_policy,
        request.project_root
      ],
      &(not is_nil(&1))
    )
  end

  defp agent_source(opts) do
    if Keyword.has_key?(opts, :agent_source), do: Keyword.get(opts, :agent_source), else: nil
  end

  defp policy(opts) do
    canonical? = Keyword.has_key?(opts, :execution_policy)
    legacy? = Keyword.has_key?(opts, :coding_profile)

    cond do
      canonical? and legacy? ->
        {:error, :conflicting_execution_policy_inputs}

      canonical? ->
        normalize_policy(Keyword.get(opts, :execution_policy))

      legacy? ->
        normalize_policy(Keyword.get(opts, :coding_profile))

      true ->
        {:ok, nil}
    end
  end

  defp normalize_policy(nil), do: {:error, {:invalid_execution_policy_input, nil}}

  defp normalize_policy(value) when is_binary(value) do
    case ExecutionPolicy.normalize_id(value) do
      "" -> {:error, {:invalid_execution_policy_input, value}}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_policy(value), do: {:error, {:invalid_execution_policy_input, value}}

  defp explicit(opts, key), do: if(Keyword.has_key?(opts, key), do: Keyword.get(opts, key), else: nil)
  defp optional_string(nil), do: {:ok, nil}
  defp optional_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp optional_string(value), do: {:error, {:invalid_binding_request_value, value}}
end
