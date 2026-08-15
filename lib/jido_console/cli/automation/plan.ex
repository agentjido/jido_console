defmodule Jido.Console.Automation.Plan do
  @moduledoc "Builds the agent, scenario, model, and trial run matrix."

  alias Jido.Console.Automation.{Contract, EnvironmentProjection, Limits, Loader, Replay}
  alias Jido.Console.Extensions
  alias Jido.Console.Release.Identity
  alias Jidoka.Agent.Spec
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.ProfileResolver

  @doc "Builds validated run cells in stable matrix order."
  @spec build(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def build(suite, opts \\ []) when is_map(suite) do
    run_id = Keyword.get_lazy(opts, :run_id, &run_id/0)

    with {:ok, agents} <- load_agents(suite.agents, opts),
         {:ok, variants} <- agent_model_variants(agents, suite.models),
         {:ok, limits} <- Limits.resolve(suite, length(variants), opts),
         {:ok, cells} <- cells(suite, variants, run_id, limits, opts) do
      {:ok,
       %{
         run_id: run_id,
         suite_id: suite.id,
         suite: suite,
         limits: limits,
         cells: cells,
         manifest: manifest(suite, variants, cells, run_id, limits)
       }}
    end
  end

  defp load_agents(agent_entries, opts) do
    agent_entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case Loader.load_agent(entry.file, Keyword.get(opts, :import_opts, [])) do
        {:ok, loaded} ->
          agent =
            entry
            |> Map.merge(loaded)
            |> Map.put(:runtime_opts, Keyword.get(opts, :runtime_opts, []))

          {:cont, {:ok, [agent | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> reverse_result()
  end

  defp agent_model_variants(agents, models) do
    agents
    |> Enum.reduce_while({:ok, []}, fn agent, {:ok, acc} ->
      models
      |> Enum.reduce_while({:ok, []}, fn model, {:ok, model_acc} ->
        case effective_spec(agent.spec, model) do
          {:ok, spec} ->
            variant = %{
              agent_key: agent.key,
              agent_spec_id: spec.id,
              agent_path: agent.path,
              agent_digest: agent.digest,
              runtime_opts: agent.runtime_opts,
              model_key: model.key,
              model_ref: Jidoka.Config.model_ref(spec.model),
              effective_spec_digest: spec_digest(spec),
              spec: spec
            }

            {:cont, {:ok, [variant | model_acc]}}

          {:error, reason} ->
            {:halt, {:error, {:model_override_failed, agent.key, model.key, reason}}}
        end
      end)
      |> case do
        {:ok, variants} -> {:cont, {:ok, acc ++ Enum.reverse(variants)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp effective_spec(spec, %{source: :agent}), do: Spec.from_input(spec)

  defp effective_spec(spec, %{source: :override} = model) do
    attrs =
      spec
      |> Map.from_struct()
      |> Map.put(:model, model.ref)
      |> maybe_put_generation(model.generation)

    Spec.new(attrs)
  end

  defp maybe_put_generation(attrs, nil), do: attrs
  defp maybe_put_generation(attrs, generation), do: Map.put(attrs, :generation, generation)

  defp cells(suite, variants, run_id, limits, opts) do
    combinations =
      for variant <- variants,
          scenario <- suite.scenarios,
          trial <- 1..suite.repeats,
          do: {variant, scenario, trial}

    combinations
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {{variant, scenario, trial}, sequence}, {:ok, acc} ->
      case build_cell(suite, variant, scenario, trial, sequence, run_id, limits, opts) do
        {:ok, cell} -> {:cont, {:ok, [cell | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_result()
  end

  defp build_cell(suite, variant, scenario, trial, sequence, run_id, limits, opts) do
    dimensions = %{
      suite_id: suite.id,
      agent_key: variant.agent_key,
      agent_spec_id: variant.agent_spec_id,
      scenario_id: scenario.id,
      model_key: variant.model_key,
      model_ref: variant.model_ref,
      trial: trial
    }

    with {:ok, environment} <- execution_environment(suite, scenario, variant.spec, opts),
         {:ok, replay} <- Replay.resolve(environment, opts),
         {:ok, extensions} <- Extensions.resolve(variant.spec.extensions, :automation, opts) do
      {:ok,
       %{
         run_id: run_id,
         cell_id: cell_id(dimensions),
         sequence: sequence,
         dimensions: dimensions,
         scenario: scenario,
         spec: variant.spec,
         runtime_opts: variant.runtime_opts,
         runtime_limits: limits,
         execution_environment: environment,
         capability_replay: replay,
         extensions: extensions,
         sources: %{
           agent_file: variant.agent_path,
           scenario_file: scenario.path,
           agent_sha256: variant.agent_digest,
           effective_agent_sha256: variant.effective_spec_digest,
           scenario_sha256: scenario.digest
         }
       }}
    end
  end

  defp execution_environment(suite, scenario, spec, opts) do
    profile_id =
      Map.get(suite, :command_execution_profile) ||
        Map.get(scenario, :execution_profile) ||
        spec.execution_profile ||
        Map.get(suite, :execution_profile)

    resolve_execution_profile(profile_id, opts)
  end

  defp resolve_execution_profile(nil, _opts), do: {:ok, nil}

  defp resolve_execution_profile(profile_id, opts) do
    resolver =
      Keyword.get(opts, :execution_profile_resolver) ||
        Application.get_env(:jido_console, :execution_profile_resolver)

    if is_nil(resolver) do
      {:error, {:missing_execution_profile_resolver, profile_id}}
    else
      with :ok <- ensure_resolver_loaded(resolver),
           {:ok, request} <- PolicyRequest.new(profile_id: profile_id),
           {:ok, registration} <-
             ProfileResolver.resolve(
               request,
               resolver,
               Keyword.get(opts, :execution_profile_resolver_opts, [])
             ) do
        {:ok, %{request: request, registration: registration}}
      end
    end
  end

  defp ensure_resolver_loaded(resolver) when is_atom(resolver) do
    case Code.ensure_loaded(resolver) do
      {:module, ^resolver} -> :ok
      {:error, reason} -> {:error, {:profile_resolver_load_failed, resolver, reason}}
    end
  end

  defp ensure_resolver_loaded(resolver) when is_function(resolver, 2), do: :ok
  defp ensure_resolver_loaded(_resolver), do: :ok

  defp manifest(suite, variants, cells, run_id, limits) do
    Contract.manifest!(%{
      schema: "jido.run-manifest",
      schema_version: 1,
      run_id: run_id,
      suite_id: suite.id,
      suite_file: suite.path,
      suite_sha256: suite.digest,
      versions: %{
        jido_console: Identity.version(),
        jidoka: application_version(:jidoka),
        elixir: System.version(),
        otp: List.to_string(:erlang.system_info(:otp_release))
      },
      matrix: %{
        agents: Enum.map(variants, & &1.agent_key) |> Enum.uniq(),
        models: Enum.map(variants, & &1.model_key) |> Enum.uniq(),
        scenarios: Enum.map(suite.scenarios, & &1.id),
        repeats: suite.repeats,
        cells: length(cells)
      },
      runtime_limits: Limits.manifest(limits),
      cells:
        Enum.map(cells, fn cell ->
          %{
            sequence: cell.sequence,
            cell_id: cell.cell_id,
            dimensions: cell.dimensions,
            sources: cell.sources,
            execution_environment: manifest_environment(cell.execution_environment),
            capability_replay: Replay.projection(cell.capability_replay),
            extensions: %{"jido.cli.trust" => cell.extensions.projection}
          }
        end)
    })
  end

  defp manifest_environment(nil), do: %{status: :not_requested}

  defp manifest_environment(environment) do
    EnvironmentProjection.project(
      %{execution_environment: environment},
      nil,
      nil
    )
    |> Map.put(:status, :resolved)
  end

  defp cell_id(dimensions) do
    [
      dimensions.suite_id,
      dimensions.agent_key,
      dimensions.agent_spec_id,
      dimensions.scenario_id,
      dimensions.model_key,
      dimensions.model_ref,
      Integer.to_string(dimensions.trial)
    ]
    |> Enum.join(<<0>>)
    |> Loader.digest()
  end

  defp spec_digest(spec) do
    spec
    |> Jidoka.project()
    |> canonical_term()
    |> :erlang.term_to_binary([:deterministic])
    |> Loader.digest()
  end

  defp canonical_term(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical_term(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_term(list) when is_list(list), do: Enum.map(list, &canonical_term/1)
  defp canonical_term(value), do: value

  defp run_id do
    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%dT%H%M%S.%fZ")

    suffix = System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)
    "run-#{timestamp}-#{suffix}"
  end

  defp application_version(application) do
    case Application.spec(application, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result(error), do: error
end
