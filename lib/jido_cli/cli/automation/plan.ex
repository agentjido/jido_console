defmodule Jido.Cli.Automation.Plan do
  @moduledoc "Builds the agent, scenario, model, and trial run matrix."

  alias Jido.Cli.Automation.{Contract, Loader}
  alias Jidoka.Agent.Spec

  @doc "Builds validated run cells in stable matrix order."
  @spec build(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def build(suite, opts \\ []) when is_map(suite) do
    run_id = Keyword.get_lazy(opts, :run_id, &run_id/0)

    with {:ok, agents} <- load_agents(suite.agents, opts),
         {:ok, variants} <- agent_model_variants(agents, suite.models),
         {:ok, cells} <- cells(suite, variants, run_id) do
      {:ok,
       %{
         run_id: run_id,
         suite_id: suite.id,
         suite: suite,
         cells: cells,
         manifest: manifest(suite, variants, cells, run_id)
       }}
    end
  end

  defp load_agents(agent_entries, opts) do
    agent_entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, profile} <- runtime_profile(entry.runtime_profile, opts),
           import_opts <-
             Keyword.merge(
               Keyword.get(opts, :import_opts, []),
               profile.import_opts
             ),
           {:ok, loaded} <- Loader.load_agent(entry.file, import_opts) do
        agent =
          entry
          |> Map.merge(loaded)
          |> Map.put(
            :runtime_opts,
            Keyword.merge(profile.run_opts, Keyword.get(opts, :runtime_opts, []))
          )

        {:cont, {:ok, [agent | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_result()
  end

  defp runtime_profile(nil, _opts), do: {:ok, %{import_opts: [], run_opts: []}}

  defp runtime_profile(name, opts) do
    profiles =
      Keyword.get_lazy(opts, :runtime_profiles, fn ->
        Application.get_env(:jido_cli, :automation_runtime_profiles, %{})
      end)

    case profile_value(profiles, name) do
      nil -> {:error, {:unknown_runtime_profile, name}}
      profile -> normalize_profile(name, profile)
    end
  end

  defp profile_value(profiles, name) when is_map(profiles) do
    Map.get(profiles, name) ||
      Enum.find_value(profiles, fn
        {key, value} when is_atom(key) -> if Atom.to_string(key) == name, do: value
        _entry -> nil
      end)
  end

  defp profile_value(profiles, name) when is_list(profiles) do
    Enum.find_value(profiles, fn {key, value} -> if to_string(key) == name, do: value end)
  end

  defp profile_value(_profiles, _name), do: nil

  defp normalize_profile(name, profile) when is_map(profile) do
    normalize_profile(name,
      import_opts: Map.get(profile, :import_opts, Map.get(profile, "import_opts", [])),
      run_opts: Map.get(profile, :run_opts, Map.get(profile, "run_opts", []))
    )
  end

  defp normalize_profile(_name, profile) when is_list(profile) do
    import_opts = Keyword.get(profile, :import_opts, [])
    run_opts = Keyword.get(profile, :run_opts, [])

    if Keyword.keyword?(import_opts) and Keyword.keyword?(run_opts) do
      {:ok, %{import_opts: import_opts, run_opts: run_opts}}
    else
      {:error, {:invalid_runtime_profile, profile}}
    end
  end

  defp normalize_profile(name, profile), do: {:error, {:invalid_runtime_profile, name, profile}}

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
              runtime_profile: agent.runtime_profile,
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

  defp cells(suite, variants, run_id) do
    cells =
      for variant <- variants,
          scenario <- suite.scenarios,
          trial <- 1..suite.repeats do
        dimensions = %{
          suite_id: suite.id,
          agent_key: variant.agent_key,
          agent_spec_id: variant.agent_spec_id,
          scenario_id: scenario.id,
          model_key: variant.model_key,
          model_ref: variant.model_ref,
          trial: trial
        }

        %{
          run_id: run_id,
          cell_id: cell_id(dimensions),
          dimensions: dimensions,
          scenario: scenario,
          spec: variant.spec,
          runtime_opts: variant.runtime_opts,
          sources: %{
            agent_file: variant.agent_path,
            scenario_file: scenario.path,
            agent_sha256: variant.agent_digest,
            effective_agent_sha256: variant.effective_spec_digest,
            scenario_sha256: scenario.digest
          }
        }
      end
      |> Enum.with_index(1)
      |> Enum.map(fn {cell, sequence} -> Map.put(cell, :sequence, sequence) end)

    {:ok, cells}
  end

  defp manifest(suite, variants, cells, run_id) do
    Contract.manifest!(%{
      schema: "jido.run-manifest",
      schema_version: 1,
      run_id: run_id,
      suite_id: suite.id,
      suite_file: suite.path,
      suite_sha256: suite.digest,
      versions: %{
        jido_cli: Jido.Cli.version(),
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
      cells:
        Enum.map(cells, fn cell ->
          %{
            sequence: cell.sequence,
            cell_id: cell.cell_id,
            dimensions: cell.dimensions,
            sources: cell.sources
          }
        end)
    })
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
