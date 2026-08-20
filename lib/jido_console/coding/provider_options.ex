defmodule Jido.Console.Coding.ProviderOptions do
  @moduledoc "Applies local coding model and provider options to an agent specification."

  alias Jidoka.Agent.Spec.Generation

  @doc "Tunes an agent specification for the selected trusted coding profile."
  @spec tune_spec(Jidoka.Agent.Spec.t(), map(), keyword()) ::
          {:ok, Jidoka.Agent.Spec.t()} | {:error, term()}
  def tune_spec(spec, selection, opts) do
    local? = local_execution?(selection.profile_id)
    model = Keyword.get(opts, :model, if(local?, do: "openai:gpt-4.1-mini", else: nil))

    attrs =
      spec
      |> Map.from_struct()
      |> maybe_put_model(model)
      |> maybe_put_local_instructions(local?)
      |> maybe_put_local_generation(local?, model || Jidoka.Config.model_ref(spec.model))
      |> maybe_put_local_runtime(local?)

    Jidoka.Agent.Spec.new(attrs)
  end

  @doc "Returns turn options for the selected coding profile and model."
  @spec turn_opts(String.t(), String.t()) :: keyword()
  def turn_opts(profile_id, "openai:" <> _model) do
    if local_execution?(profile_id) do
      [
        llm_opts: [provider_options: [response_format: openai_decision_format()]],
        max_parallel_operations: 1
      ]
    else
      []
    end
  end

  def turn_opts(profile_id, _model) do
    if local_execution?(profile_id), do: [max_parallel_operations: 1], else: []
  end

  defp local_execution?(profile_id) when is_binary(profile_id), do: profile_id != ""
  defp local_execution?(_profile_id), do: false

  defp maybe_put_model(attrs, nil), do: attrs
  defp maybe_put_model(attrs, model), do: Map.put(attrs, :model, model)

  defp maybe_put_local_instructions(attrs, false), do: attrs

  defp maybe_put_local_instructions(attrs, true) do
    local_instructions = """

    Local coding tools are available. Use the exact full operation names below.
    Return one top-level decision, then stop and wait for the tool observation.
    Do not simulate later tool calls and do not ask the user to supply tool output.

    Minimal valid calls:
    - coding.read: {"path":"relative/file"}
    - coding.search: {"mode":"text","path":".","pattern":"literal text"}
    - coding.search (list paths): {"mode":"path","path":".","pattern":"*"}
    - coding.edit: {"path":"relative/file","old_text":"exact text","new_text":"replacement"}
    - coding.write: {"path":"relative/file","content":"complete content"}
    - coding.git_status: {}
    - coding.git_diff: {}
    - coding.verify: {"helper_id":"mix-test"}

    There is no general shell operation. Never shorten an operation name, such
    as `read`, `edit`, or `verify`. A path value must be a plain relative path.
    Do not include quotation-mark characters inside the path value.
    Use coding.search with mode `path` to list files or directories.
    coding.git_status shows changed files only. A clean status does not mean
    that the directory is empty.
    For a repository overview, inspect the repository instead of answering from project instructions alone.
    Start with a root path search, then read the README and the main build manifest when they exist.
    For a normal text read, omit byte offsets and lengths unless you continue a truncated result.
    """

    Map.update!(attrs, :instructions, &(&1 <> local_instructions))
  end

  defp maybe_put_local_generation(attrs, false, _model), do: attrs

  defp maybe_put_local_generation(attrs, true, model) do
    Map.put(attrs, :generation, Generation.new!(params: local_generation_params(model)))
  end

  defp local_generation_params("openai:gpt-5" <> _model) do
    %{max_tokens: 4_000, reasoning_effort: :low}
  end

  defp local_generation_params("openai:" <> _model),
    do: %{max_tokens: 4_000, temperature: 0.0}

  defp local_generation_params("anthropic:" <> _model),
    do: %{max_tokens: 4_000, temperature: 0.0}

  defp local_generation_params(_model), do: %{max_tokens: 4_000}

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

  defp maybe_put_local_runtime(attrs, false), do: attrs

  defp maybe_put_local_runtime(attrs, true) do
    defaults =
      Map.merge(attrs.runtime_defaults, %{
        max_model_turns: 12,
        timeout_ms: 180_000
      })

    Map.put(attrs, :runtime_defaults, defaults)
  end
end
