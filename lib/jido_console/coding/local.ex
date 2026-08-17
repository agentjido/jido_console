defmodule Jido.Console.Coding.Local do
  @moduledoc "Trusted local-folder ports for an explicitly selected coding profile."

  alias Jidoka.CodingPack.{GitPort, MutationPort, ShellPort, VerifyPort, Workspace}
  alias Jidoka.ExecutionEnvironment

  alias Jidoka.ExecutionEnvironment.{
    AdapterCapabilities,
    Manager,
    PolicyRequest,
    ProfileResolver,
    Registration,
    SecurityProfile
  }

  alias Jidoka.Policy.Decision
  alias Jido.Console.Coding.Environment
  alias Jido.Console.Coding.Environment.Contract
  alias Jido.Console.Coding.Local.{Resources, Setup}

  @profile_id "coding.local"
  @adapter_id "jido_console.local_folder"
  @adapter_version "1"
  @wall_time_ms 120_000
  @output_bytes 262_144

  @type resources :: Resources.t()

  @doc "Returns the explicit trusted profile identifier."
  @spec profile_id() :: String.t()
  def profile_id, do: @profile_id

  @doc "Creates folder-scoped coding ports for one validated workspace."
  @spec prepare(Workspace.t(), Contract.t()) :: {:ok, map()} | {:error, term()}
  def prepare(%Workspace{} = workspace, %Contract{} = environment_contract) do
    with true <- Code.ensure_loaded?(Jido.Console.Coding.Local.Adapter),
         true <- Code.ensure_loaded?(Jido.Console.Coding.Local.MutationBackend),
         {:ok, executables} <- executables(),
         {:ok, mutation_state} <-
           Agent.start_link(fn -> %{snapshots: %{}, snapshot_bytes: 0} end) do
      case prepare_resources(workspace, environment_contract, executables, mutation_state) do
        {:ok, _local} = success ->
          success

        {:error, _reason} = error ->
          stop_mutation_state(mutation_state)
          error
      end
    else
      false ->
        {:error, :local_coding_module_unavailable}

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_resources(workspace, environment_contract, executables, mutation_state) do
    profile = profile(environment_contract)
    request = PolicyRequest.new!(profile_id: profile.profile_id)
    registration = registration(profile)

    manager_opts = [
      workspace: workspace,
      executables: executables,
      environment_contract: environment_contract
    ]

    with {:ok, selection} <-
           ProfileResolver.resolve(request, fn _profile_id, _opts -> {:ok, registration} end),
         {:ok, manager} <- Manager.start_link(selection, policy(), manager_opts) do
      prepare_binding(manager, request, profile, mutation_state, environment_contract)
    end
  end

  defp prepare_binding(manager, request, profile, mutation_state, environment_contract) do
    case Manager.open(manager, request) do
      {:ok, binding, evidence} ->
        prepare_ports(manager, binding, profile, mutation_state, environment_contract, evidence)

      {:error, _reason} = error ->
        stop_manager(manager, nil, error)
    end
  end

  defp prepare_ports(manager, binding, profile, mutation_state, environment_contract, environment_evidence) do
    with {:ok, mutation} <-
           MutationPort.new(Jido.Console.Coding.Local.MutationBackend,
             state: mutation_state,
             profile_digest: profile.digest
           ),
         {:ok, shell} <-
           ShellPort.new(manager, binding, profile, %{
             "git" => %{class: "git", mutation: "read", network: false},
             "mix" => %{class: "verify", mutation: "read", network: false}
           }),
         {:ok, git} <- GitPort.new(shell),
         {:ok, verify} <- VerifyPort.new(shell, verify_helpers()) do
      {:ok,
       %Setup{
         mutation: mutation,
         shell: shell,
         git: git,
         verify: verify,
         disable_tools: ["coding.shell"],
         resources: %Resources{
           manager: manager,
           binding: binding,
           mutation_state: mutation_state,
           environment_contract: environment_contract,
           environment_evidence: environment_evidence
         }
       }}
    else
      {:error, _reason} = error -> stop_manager(manager, binding, error)
    end
  end

  @doc "Stops local resources created for one interactive coding session."
  @spec close(resources() | nil) :: :ok
  def close(nil), do: :ok

  def close(%Resources{manager: manager, binding: binding, mutation_state: mutation_state}) do
    if Process.alive?(manager) do
      _result = Manager.cleanup(manager, binding)
      GenServer.stop(manager, :normal)
    end

    stop_mutation_state(mutation_state)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp profile(%Contract{} = environment_contract) do
    digest =
      ExecutionEnvironment.digest(%{
        profile_id: environment_contract.profile_id,
        adapter_id: @adapter_id,
        revision: 1,
        isolation: :process,
        network: :disabled,
        workspace: :persistent,
        wall_time_ms: @wall_time_ms,
        output_bytes: @output_bytes,
        environment_contract: Environment.digest(environment_contract)
      })

    SecurityProfile.new!(
      profile_id: environment_contract.profile_id,
      revision: 1,
      digest: digest,
      adapter_id: @adapter_id,
      required_isolation: :process,
      required_network: :disabled,
      required_workspace: :persistent,
      maximum_limits: %{
        "wall_time_ms" => @wall_time_ms,
        "output_bytes" => @output_bytes
      }
    )
  end

  defp registration(profile) do
    capabilities =
      AdapterCapabilities.new!(
        adapter_id: @adapter_id,
        adapter_version: @adapter_version,
        isolations: [:process],
        networks: [:disabled],
        workspaces: [:persistent],
        limit_keys: ["wall_time_ms", "output_bytes"],
        capability_ids: ["shell.execute"]
      )

    Registration.new!(
      profile: profile,
      adapter: Jido.Console.Coding.Local.Adapter,
      capabilities: capabilities
    )
  end

  defp policy do
    fn request, _context ->
      outcome = if allowed_request?(request), do: :allow, else: :deny
      {:ok, Decision.new!(outcome: outcome, rule_id: "jido_console.local_folder.#{outcome}")}
    end
  end

  defp allowed_request?(%{action: "execute", resource: resource}) do
    Map.get(resource, "network") == false and
      Map.get(resource, "command") in ["git", "mix"] and
      Map.get(resource, "mutation") == "read"
  end

  defp allowed_request?(%{action: action})
       when action in ["open", "acquire", "close", "cleanup"],
       do: true

  defp allowed_request?(_request), do: false

  defp executables do
    with git when is_binary(git) <- System.find_executable("git"),
         mix when is_binary(mix) <- System.find_executable("mix") do
      {:ok, %{"git" => git, "mix" => mix, "sandbox-exec" => System.find_executable("sandbox-exec")}}
    else
      _missing -> {:error, :local_coding_executable_missing}
    end
  end

  defp verify_helpers do
    %{
      "mix-test" => %{
        description: "Run the complete isolated Mix test suite.",
        command: "mix",
        args: ["test"],
        targets: [],
        timeout_ms: @wall_time_ms,
        network: false,
        exit_codes: [0]
      }
    }
  end

  defp stop_manager(manager, binding, error) do
    if Process.alive?(manager) do
      if binding, do: Manager.cleanup(manager, binding)
      GenServer.stop(manager, :normal)
    end

    error
  catch
    :exit, _reason -> error
  end

  defp stop_mutation_state(mutation_state) do
    if Process.alive?(mutation_state), do: Agent.stop(mutation_state, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
