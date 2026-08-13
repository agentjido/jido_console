defmodule Jido.Cli.CodingSetup do
  @moduledoc "Trusted CLI selection and context for the removable Jidoka coding pack."

  alias Jido.Cli.{Extensions, LocalCoding}
  alias Jidoka.Agent.Spec.Generation
  alias Jidoka.CodingPack
  alias Jidoka.CodingPack.{Instructions, Workspace}
  alias Jidoka.Extension.Request

  @default_pack CodingPack.id()
  @default_profile "coding.default"

  @type t :: %{
          spec: Jidoka.Agent.Spec.t(),
          extension_setup: map(),
          workspace: Workspace.t() | nil,
          instructions: [map()],
          context: map(),
          pack_id: String.t() | nil,
          profile_id: String.t() | nil,
          local_resources: LocalCoding.resources() | nil,
          await_timeout_ms: pos_integer(),
          turn_opts: keyword()
        }

  @doc "Resolves the trusted interactive coding setup."
  @spec prepare(module() | Jidoka.Agent.Spec.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def prepare(agent, opts) when is_list(opts) do
    with {:ok, spec} <- spec(agent),
         {:ok, selection} <- selection(opts),
         {:ok, spec} <- tune_spec(spec, selection, opts),
         {:ok, setup} <- configure(spec, selection, opts) do
      {:ok, setup}
    end
  end

  @doc "Closes trusted local resources held by one resolved setup."
  @spec close(t()) :: :ok
  def close(%{local_resources: resources}), do: LocalCoding.close(resources)

  @doc "Resolves file mentions and returns portable Jidoka context data."
  @spec prepare_prompt(t(), String.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def prepare_prompt(%{workspace: nil, context: context}, prompt), do: {:ok, unescape(prompt), context}

  def prepare_prompt(%{workspace: workspace, context: context}, prompt) do
    with {:ok, prompt, files} <- Jido.Cli.FileMentions.resolve(workspace, prompt) do
      coding = context["coding"] |> Map.put("files", files)
      {:ok, prompt, put_in(context, ["coding"], coding)}
    end
  end

  defp configure(spec, %{pack_id: nil}, opts) do
    extensions = Enum.reject(spec.extensions, &(&1.id == @default_pack))

    with {:ok, spec} <- Jidoka.Agent.Spec.new(spec |> Map.from_struct() |> Map.put(:extensions, extensions)),
         {:ok, extension_setup} <- Extensions.resolve(extensions, :interactive, opts) do
      {:ok,
       %{
         spec: spec,
         extension_setup: %{
           extension_setup
           | projection: %{
               "status" => "disabled",
               "other_extensions" => extension_setup.projection
             }
         },
         workspace: nil,
         instructions: [],
         context: %{"coding" => %{"status" => "disabled"}},
         pack_id: nil,
         profile_id: nil,
         local_resources: nil,
         await_timeout_ms: 30_000,
         turn_opts: []
       }}
    end
  end

  defp configure(spec, selection, opts) do
    with :ok <- validate_profile(selection.profile_id, opts),
         {:ok, workspace} <- workspace(selection.profile_id, opts),
         {:ok, instructions} <- Instructions.discover(workspace, working_directory(opts)),
         {:ok, local} <- local_profile(selection.profile_id, workspace) do
      finish_configuration(spec, selection, workspace, instructions, local, opts)
    end
  end

  defp finish_configuration(spec, selection, workspace, instructions, local, opts) do
    try do
      result =
        with request = Request.new!(id: selection.pack_id),
             {:ok, spec} <- put_request(spec, request),
             {:ok, extension_setup} <-
               extension_setup(selection.pack_id, spec.extensions, workspace, local, opts) do
          context = %{
            "coding" => %{
              "status" => "enabled",
              "pack_id" => selection.pack_id,
              "profile_id" => selection.profile_id,
              "workspace" => Workspace.to_map(workspace),
              "instructions" => instructions,
              "files" => []
            }
          }

          {:ok,
           %{
             spec: spec,
             extension_setup: extension_setup,
             workspace: workspace,
             instructions: instructions,
             context: context,
             pack_id: selection.pack_id,
             profile_id: selection.profile_id,
             local_resources: Map.get(local, :resources),
             await_timeout_ms: if(selection.profile_id == LocalCoding.profile_id(), do: 180_000, else: 30_000),
             turn_opts: local_turn_opts(selection.profile_id, Jidoka.Config.model_ref(spec.model))
           }}
        end

      case result do
        {:ok, _setup} = success ->
          success

        {:error, _reason} = error ->
          LocalCoding.close(Map.get(local, :resources))
          error
      end
    rescue
      exception ->
        LocalCoding.close(Map.get(local, :resources))
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        LocalCoding.close(Map.get(local, :resources))
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp extension_setup(@default_pack, requests, workspace, local, opts) do
    entry_opts =
      [
        mutation: Keyword.get(opts, :coding_mutation_port, Map.get(local, :mutation)),
        shell: Keyword.get(opts, :coding_shell_port, Map.get(local, :shell)),
        git: Keyword.get(opts, :coding_git_port, Map.get(local, :git)),
        verify: Keyword.get(opts, :coding_verify_port, Map.get(local, :verify)),
        replace_tools: Keyword.get(opts, :coding_replace_tools, %{}),
        disable_tools: Enum.uniq(Keyword.get(opts, :coding_disable_tools, []) ++ Map.get(local, :disable_tools, []))
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    other_requests = Enum.reject(requests, &(&1.id == @default_pack))

    with {:ok, entry} <- CodingPack.entry(workspace, entry_opts),
         {:ok, other_setup} <- Extensions.resolve(other_requests, :interactive, opts) do
      {:ok,
       %{
         registry: Map.put(other_setup.registry, @default_pack, entry),
         recover_coding_errors: Map.has_key?(local, :resources),
         projection: %{
           "status" => "trusted",
           "records" =>
             [%{"id" => @default_pack, "source" => "built_in"}] ++
               Map.get(other_setup.projection, "records", [])
         }
       }}
    end
  end

  defp extension_setup(_replacement, requests, _workspace, _local, opts),
    do: Extensions.resolve(requests, :interactive, opts)

  defp workspace(profile_id, opts) do
    root = Keyword.get(opts, :project_root, Application.get_env(:jido_cli, :project_root))

    if profile_id == LocalCoding.profile_id() and is_nil(root) do
      {:error, :local_coding_root_required}
    else
      build_workspace(profile_id, root || File.cwd!(), opts)
    end
  end

  defp build_workspace(profile_id, root, opts) do
    local? = profile_id == LocalCoding.profile_id()

    Workspace.new(
      root: root,
      access:
        Keyword.get(
          opts,
          :coding_access,
          Application.get_env(
            :jido_cli,
            :coding_access,
            if(local?, do: [:read, :write, :shell, :git, :verify], else: [:read])
          )
        ),
      limits:
        Keyword.get(
          opts,
          :coding_limits,
          Application.get_env(
            :jido_cli,
            :coding_limits,
            if(local?,
              do: %{
                max_file_bytes: 262_144,
                max_result_bytes: 262_144,
                max_search_files: 2_000,
                max_search_results: 100,
                max_shell_args: 32,
                max_shell_stdin_bytes: 1,
                max_shell_output_bytes: 262_144,
                max_shell_timeout_ms: 120_000
              },
              else: %{}
            )
          )
        ),
      execution_profile: profile_id
    )
  end

  defp selection(opts) do
    pack = Keyword.get(opts, :coding_pack, Application.get_env(:jido_cli, :coding_pack, @default_pack))
    profile = Keyword.get(opts, :coding_profile, Application.get_env(:jido_cli, :coding_profile, @default_profile))

    cond do
      pack in [false, :disabled, "disabled", nil] -> {:ok, %{pack_id: nil, profile_id: nil}}
      not (is_binary(pack) and pack != "") -> {:error, {:invalid_coding_pack, pack}}
      not (is_binary(profile) and profile != "") -> {:error, {:invalid_execution_profile, profile}}
      module_name?(pack) or module_name?(profile) -> {:error, :coding_module_name_forbidden}
      true -> {:ok, %{pack_id: pack, profile_id: profile}}
    end
  end

  defp validate_profile(profile_id, opts) do
    case Keyword.get(opts, :coding_profile_resolver, Application.get_env(:jido_cli, :coding_profile_resolver)) do
      nil -> :ok
      resolver when is_function(resolver, 1) -> normalize_profile_result(resolver.(profile_id), profile_id)
      _resolver -> {:error, :invalid_coding_profile_resolver}
    end
  end

  defp normalize_profile_result({:ok, _profile}, _id), do: :ok
  defp normalize_profile_result(:ok, _id), do: :ok
  defp normalize_profile_result({:error, reason}, id), do: {:error, {:unknown_runtime_profile, id, reason}}
  defp normalize_profile_result(_result, id), do: {:error, {:unknown_runtime_profile, id}}

  defp local_profile(profile_id, workspace) do
    if profile_id == LocalCoding.profile_id(), do: LocalCoding.prepare(workspace), else: {:ok, %{}}
  end

  defp tune_spec(spec, selection, opts) do
    local? = selection.profile_id == LocalCoding.profile_id()
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
    - coding.edit: {"path":"relative/file","old_text":"exact text","new_text":"replacement"}
    - coding.write: {"path":"relative/file","content":"complete content"}
    - coding.git_status: {}
    - coding.git_diff: {}
    - coding.verify: {"helper_id":"mix-test"}

    There is no general shell operation. Never shorten an operation name, such
    as `read`, `edit`, or `verify`. A path value must be a plain relative path.
    Do not include quotation-mark characters inside the path value.
    """

    Map.update!(attrs, :instructions, &(&1 <> local_instructions))
  end

  defp maybe_put_local_generation(attrs, false, _model), do: attrs

  defp maybe_put_local_generation(attrs, true, model) do
    Map.put(
      attrs,
      :generation,
      Generation.new!(params: local_generation_params(model))
    )
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

  defp local_turn_opts(profile_id, "openai:" <> _model) do
    if profile_id == LocalCoding.profile_id() do
      [
        llm_opts: [provider_options: [response_format: openai_decision_format()]],
        max_parallel_operations: 1
      ]
    else
      []
    end
  end

  defp local_turn_opts(profile_id, _model) do
    if profile_id == LocalCoding.profile_id(), do: [max_parallel_operations: 1], else: []
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

  defp put_request(spec, request) do
    extensions = [request | Enum.reject(spec.extensions, &(&1.id == request.id))]
    Jidoka.Agent.Spec.new(spec |> Map.from_struct() |> Map.put(:extensions, extensions))
  end

  defp spec(agent) when is_atom(agent) do
    if Code.ensure_loaded?(agent) and function_exported?(agent, :spec, 0),
      do: {:ok, agent.spec()},
      else: {:error, :invalid_coding_agent}
  end

  defp spec(%Jidoka.Agent.Spec{} = spec), do: {:ok, spec}
  defp spec(_agent), do: {:error, :invalid_coding_agent}

  defp module_name?(value), do: String.starts_with?(value, ["Elixir.", ":"]) or String.contains?(value, "/")
  defp unescape(prompt), do: String.replace(prompt, "\\@", "@")

  defp working_directory(opts),
    do: Keyword.get(opts, :coding_working_directory, Application.get_env(:jido_cli, :coding_working_directory, "."))
end
