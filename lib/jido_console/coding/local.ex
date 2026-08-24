defmodule Jido.Console.Coding.Local do
  @moduledoc "Post-selection resource opener for a trusted execution-policy record."

  alias Jidoka.CodingPack.{GitPort, MutationPort, ShellPort, VerifyPort, Workspace}
  alias Jidoka.ExecutionEnvironment.Manager

  alias Jidoka.Policy.Decision
  alias Jido.Console.Coding.Environment.Contract
  alias Jido.Console.Coding.Local.{Resources, Setup}
  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.ExecutionPolicy.{Record, Registry}

  @legacy_profile_id "coding.local"
  @wall_time_ms 120_000

  @type resources :: Resources.t()

  @deprecated "Use execution_policy_id/0"
  @doc "Returns the legacy explicit trusted profile identifier."
  @spec profile_id() :: String.t()
  def profile_id, do: @legacy_profile_id

  @doc "Returns the canonical trusted-workspace execution-policy identifier."
  @spec execution_policy_id() :: String.t()
  def execution_policy_id, do: ExecutionPolicy.trusted_id()

  @deprecated "Pass an execution-policy record to prepare/3"
  @doc "Compatibility opener that resolves a host record from the environment contract."
  @spec prepare(Workspace.t(), Contract.t()) :: {:ok, map()} | {:error, term()}
  def prepare(%Workspace{} = workspace, %Contract{} = environment_contract) do
    with {:ok, record} <- Registry.fetch(environment_contract.execution_policy_id) do
      prepare(record, workspace, environment_contract)
    end
  end

  @doc "Creates folder-scoped coding ports from one validated host policy record."
  @spec prepare(Record.t(), Workspace.t(), Contract.t()) :: {:ok, map()} | {:error, term()}
  def prepare(
        %Record{} = record,
        %Workspace{} = workspace,
        %Contract{} = environment_contract
      ) do
    with true <- Code.ensure_loaded?(Jido.Console.Coding.Local.Adapter),
         true <- Code.ensure_loaded?(Jido.Console.Coding.Local.MutationBackend),
         {:ok, record} <- Record.validate(record),
         true <- record.execution_policy_id == environment_contract.execution_policy_id,
         {:ok, executables} <- executables(),
         {:ok, mutation_state} <-
           Agent.start_link(fn -> %{snapshots: %{}, snapshot_bytes: 0} end) do
      case prepare_resources(record, workspace, environment_contract, executables, mutation_state) do
        {:ok, _local} = success ->
          success

        {:error, _reason} = error ->
          stop_mutation_state(mutation_state)
          error
      end
    else
      false ->
        if Code.ensure_loaded?(Jido.Console.Coding.Local.Adapter) and
             Code.ensure_loaded?(Jido.Console.Coding.Local.MutationBackend),
           do: {:error, :environment_contract_execution_policy_mismatch},
           else: {:error, :local_coding_module_unavailable}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  def prepare(%Workspace{} = workspace, %Contract{} = contract, %Record{} = record),
    do: prepare(record, workspace, contract)

  defp prepare_resources(record, workspace, environment_contract, executables, mutation_state) do
    manager_opts = [
      workspace: workspace,
      executables: executables,
      environment_contract: environment_contract
    ]

    with {:ok, manager} <- Manager.start_link(record.jidoka_selection, policy(), manager_opts) do
      prepare_binding(
        manager,
        record.policy_request,
        record.security_profile,
        mutation_state,
        environment_contract
      )
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
