defmodule Jido.Console.Coding.ProviderOptions do
  @moduledoc "Transport-only provider options for an already bound agent specification."

  alias Jido.Console.Session.Binding

  @doc "Returns the unchanged bound spec after transport model confirmation."
  @spec tune_spec(Binding.t(), keyword()) :: {:ok, Jidoka.Agent.Spec.t()} | {:error, term()}
  def tune_spec(%Binding{} = binding, opts) when is_list(opts) do
    with :ok <- confirm_model(binding.model_id, opts),
         :ok <- reject_model_in_transport(opts) do
      {:ok, binding.bound_spec}
    end
  end

  @doc "Compatibility path that no longer retunes semantic agent fields."
  @spec tune_spec(Jidoka.Agent.Spec.t(), map(), keyword()) ::
          {:ok, Jidoka.Agent.Spec.t()} | {:error, term()}
  def tune_spec(%Jidoka.Agent.Spec{} = spec, _selection, opts) when is_list(opts) do
    with :ok <- confirm_model(Jidoka.Config.model_ref(spec.model), opts),
         :ok <- reject_model_in_transport(opts) do
      {:ok, spec}
    end
  end

  @doc "Builds provider transport options without changing the bound specification."
  @spec runtime_opts(Binding.t(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def runtime_opts(%Binding{} = binding, opts \\ []) when is_list(opts) do
    with :ok <- confirm_model(binding.model_id, opts),
         :ok <- reject_model_in_transport(opts) do
      llm_opts =
        opts
        |> Keyword.get(:llm_opts, [])
        |> maybe_put_provider_options(Keyword.get(opts, :provider_options))

      if Keyword.keyword?(llm_opts),
        do: {:ok, if(llm_opts == [], do: [], else: [llm_opts: llm_opts])},
        else: {:error, :invalid_provider_transport_options}
    end
  end

  @doc "Returns turn transport options for the selected execution policy and model."
  @spec turn_opts(String.t() | nil, String.t()) :: keyword()
  def turn_opts(execution_policy_id, "openai:" <> _model) do
    if local_execution?(execution_policy_id) do
      [
        llm_opts: [provider_options: [response_format: openai_decision_format()]],
        max_parallel_operations: 1
      ]
    else
      []
    end
  end

  def turn_opts(execution_policy_id, _model) do
    if local_execution?(execution_policy_id), do: [max_parallel_operations: 1], else: []
  end

  defp confirm_model(expected, opts) do
    case Keyword.fetch(opts, :model) do
      :error -> :ok
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, :provider_model_override_forbidden}
    end
  end

  defp reject_model_in_transport(opts) do
    llm_opts = Keyword.get(opts, :llm_opts, [])

    if Keyword.keyword?(llm_opts) and Keyword.has_key?(llm_opts, :model),
      do: {:error, :provider_model_override_forbidden},
      else: :ok
  end

  defp maybe_put_provider_options(llm_opts, nil), do: llm_opts

  defp maybe_put_provider_options(llm_opts, provider_options) when is_list(llm_opts),
    do: Keyword.put(llm_opts, :provider_options, provider_options)

  defp maybe_put_provider_options(llm_opts, _provider_options), do: llm_opts

  defp local_execution?(execution_policy_id) when is_binary(execution_policy_id),
    do: execution_policy_id != ""

  defp local_execution?(_execution_policy_id), do: false

  defp openai_decision_format do
    %{
      type: "json_schema",
      json_schema: %{
        name: "jidoka_decision",
        strict: false,
        schema: %{
          type: "object",
          properties: %{
            type: %{type: "string", enum: ["final", "operation", "operations"]},
            content: %{type: "string"},
            name: %{type: "string"},
            arguments: %{type: "object"},
            operations: %{
              type: "array",
              items: %{
                type: "object",
                properties: %{
                  name: %{type: "string"},
                  arguments: %{type: "object"}
                }
              }
            }
          },
          required: ["type"],
          additionalProperties: false
        }
      }
    }
  end
end
