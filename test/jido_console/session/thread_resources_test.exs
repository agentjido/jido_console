defmodule Jido.Console.Session.ThreadResourcesTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Extensions.Setup, as: ExtensionSetup
  alias Jido.Console.AgentSource
  alias Jido.Console.AgentSource.Record
  alias Jido.Console.Coding.Pack
  alias Jido.Console.Digest
  alias Jido.Console.ExecutionPolicy
  alias Jido.Console.Session.Binding
  alias Jido.Console.Session.ThreadResources
  alias Jidoka.Agent.Spec.{Memory, Operation}
  alias Jidoka.Session.Data

  defmodule PrivateSetup do
    def prepare(agent, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      {:ok, spec} = Jidoka.Agent.Spec.from_input(agent)
      {:ok, manager} = Agent.start_link(fn -> :ready end)
      send(test_pid, {:private_setup, Keyword.fetch!(opts, :thread_id), manager})

      {:ok,
       %{
         spec: spec,
         extension_setup: ExtensionSetup.not_requested(),
         turn_opts: [],
         pack_id: nil,
         profile_id: nil,
         local_resources: %{manager: manager}
       }}
    end

    def prepare_prompt(_setup, prompt), do: {:ok, prompt, %{}}

    def owned_processes(%{local_resources: %{manager: manager}}), do: [manager]

    def close(%{local_resources: %{manager: manager}}) do
      if Process.alive?(manager), do: Agent.stop(manager)
      :ok
    end
  end

  defmodule FailingSetup do
    def prepare(_agent, _opts), do: {:error, :setup_failed}
  end

  defmodule RaisingSetup do
    def prepare(_agent, _opts), do: raise("setup failed")
  end

  defmodule ThrowingSetup do
    def prepare(_agent, _opts), do: throw(:setup_failed)
  end

  test "two threads get distinct private resources and close independently" do
    shared_home = Path.join(System.tmp_dir!(), "jido-thread-resources-shared")
    opts = [setup_module: PrivateSetup, test_pid: self(), jido_home: shared_home]

    {:ok, first} = ThreadResources.new("thread-a", Jido.Console.DefaultAgent, opts)
    {:ok, second} = ThreadResources.new("thread-b", Jido.Console.DefaultAgent, opts)
    {:ok, first_session} = Data.start(ThreadResources.base_spec(first), session_id: "thread-a")
    {:ok, second_session} = Data.start(ThreadResources.base_spec(second), session_id: "thread-b")

    assert {:ok, first, _first_session} = ThreadResources.prepare(first, first_session)
    assert {:ok, second, _second_session} = ThreadResources.prepare(second, second_session)
    assert_receive {:private_setup, "thread-a", first_manager}
    assert_receive {:private_setup, "thread-b", second_manager}
    refute first_manager == second_manager

    assert ThreadResources.status(first) == %{
             "status" => "ready",
             "coding" => "disabled",
             "execution_policy_id" => nil
           }

    refute inspect(ThreadResources.status(first)) =~ inspect(first_manager)
    assert :ok = ThreadResources.close(first)
    refute Process.alive?(first_manager)
    assert Process.alive?(second_manager)
    assert :ok = ThreadResources.close(second)
    refute Process.alive?(second_manager)
  end

  test "keeps an unprepared handle private and reports setup failures" do
    assert {:ok, resources} =
             ThreadResources.new("thread-unprepared", Jido.Console.DefaultAgent, setup_module: FailingSetup)

    assert ThreadResources.status(resources) == %{"status" => "not_prepared"}
    assert {:error, :resources_not_prepared} = ThreadResources.prepare_prompt(resources, "prompt", %{})
    assert {:error, :setup_failed} = ThreadResources.prepare(resources, session(resources))
    assert :ok = ThreadResources.close(resources)

    for {module, expected} <- [
          {RaisingSetup, RuntimeError},
          {ThrowingSetup, {:throw, :setup_failed}}
        ] do
      assert {:ok, failing} =
               ThreadResources.new("thread-failing", Jido.Console.DefaultAgent, setup_module: module)

      assert {:error, reason} = ThreadResources.prepare(failing, session(failing))

      case expected do
        exception when is_atom(exception) -> assert %{__struct__: ^exception} = reason
        tuple -> assert reason == tuple
      end
    end
  end

  test "configures a model only before resources are prepared" do
    assert {:ok, resources} =
             ThreadResources.new("thread-model", Jido.Console.DefaultAgent,
               setup_module: PrivateSetup,
               test_pid: self()
             )

    assert {:ok, configured} = ThreadResources.configure_model(resources, "ollama:llama3.2")
    assert configured.options[:model] == "ollama:llama3.2"

    assert {:ok, prepared, _session} = ThreadResources.prepare(configured, session(configured))
    assert_receive {:private_setup, "thread-model", manager}
    assert {:error, error} = ThreadResources.configure_model(prepared, "openai:gpt-4.1-mini")
    assert Exception.message(error) =~ "locked"
    assert :ok = ThreadResources.close(prepared)
    refute Process.alive?(manager)
  end

  test "reuses prepared resources and includes a caller operation boundary" do
    operations = fn _intent, _journal, _context -> {:ok, :handled} end

    assert {:ok, resources} =
             ThreadResources.new("thread-operations", Jido.Console.DefaultAgent,
               setup_module: PrivateSetup,
               test_pid: self(),
               operations: operations
             )

    source = session(resources)
    assert {:ok, prepared, prepared_session} = ThreadResources.prepare(resources, source)
    assert_receive {:private_setup, "thread-operations", manager}
    assert ThreadResources.runtime_opts(prepared)[:operations] == operations
    assert {:ok, ^prepared, ^prepared_session} = ThreadResources.prepare(prepared, prepared_session)
    assert :ok = ThreadResources.close(prepared)
    refute Process.alive?(manager)
  end

  test "derives a fresh runtime spec from the binding and rejects caller host namespaces" do
    root = temporary_root("fresh-runtime")
    binding = build_binding(root)

    poison = Operation.new!(name: "runtime.poison", idempotency: :pure)
    prior_runtime = Jidoka.Agent.Spec.new!(%{binding.bound_spec | operations: [poison]})
    {:ok, source_session} = Data.start(prior_runtime, session_id: "fresh-runtime")

    assert {:ok, resources} =
             ThreadResources.new("fresh-runtime", binding,
               project_root: root,
               coding_pack: :disabled
             )

    assert ThreadResources.base_spec(resources) == binding.bound_spec
    assert {:ok, prepared, runtime_session} = ThreadResources.prepare(resources, source_session)
    refute Enum.any?(runtime_session.spec.operations, &(&1.name == "runtime.poison"))
    assert runtime_session.spec == binding.bound_spec
    assert ThreadResources.runtime_definition_fingerprint(prepared) == binding.runtime_definition_fingerprint

    assert {:ok, "prompt", context} =
             ThreadResources.prepare_prompt(prepared, "prompt", %{"caller" => true})

    assert context["caller"]
    assert context["jido_console"] == binding.safe_context["jido_console"]

    assert {:error, {:reserved_context_namespace, "coding"}} =
             ThreadResources.prepare_prompt(prepared, "prompt", %{"coding" => %{"forged" => true}})

    assert :ok = ThreadResources.close(prepared)
  end

  test "installs a private host memory store for session-scoped bound memory" do
    root = temporary_root("memory")
    {:ok, source} = AgentSource.resolve("builtin:jido")
    memory = Memory.new!(capture: :conversation, max_entries: 99)
    spec = Jidoka.Agent.Spec.new!(%{source.base_spec | memory: memory})
    source = source_record(source, spec)
    binding = build_binding(root, source)

    assert binding.bound_spec.memory.scope == :session
    assert binding.bound_spec.memory.max_entries == 20

    assert {:ok, resources} =
             ThreadResources.new("memory", binding, project_root: root, coding_pack: :disabled)

    assert {:ok, prepared, _session} = ThreadResources.prepare(resources, session(resources))
    assert {Jidoka.Memory.Store.InMemory, memory_opts} = ThreadResources.runtime_opts(prepared)[:memory_store]
    memory_pid = Keyword.fetch!(memory_opts, :pid)
    assert Process.alive?(memory_pid)
    assert :ok = ThreadResources.close(prepared)
    refute Process.alive?(memory_pid)
  end

  test "a dead owned process makes prepared resources unavailable" do
    assert {:ok, resources} =
             ThreadResources.new("thread-dead-resource", Jido.Console.DefaultAgent,
               setup_module: PrivateSetup,
               test_pid: self()
             )

    assert {:ok, prepared, _session} = ThreadResources.prepare(resources, session(resources))
    assert_receive {:private_setup, "thread-dead-resource", manager}
    assert ThreadResources.owned_processes(prepared) == [manager]
    Agent.stop(manager)

    assert ThreadResources.status(prepared) == %{
             "status" => "unavailable",
             "coding" => "disabled",
             "execution_policy_id" => nil
           }

    assert {:error, :resources_unavailable} = ThreadResources.prepare(prepared, session(prepared))
    assert :ok = ThreadResources.close(prepared)
  end

  defp session(resources) do
    {:ok, session} = Data.start(ThreadResources.base_spec(resources), session_id: resources.thread_id)
    session
  end

  defp build_binding(root, source \\ nil) do
    source = source || AgentSource.resolve("builtin:jido") |> elem(1)
    {:ok, pack} = Pack.resolve(coding_pack: :disabled)
    {:ok, policy} = ExecutionPolicy.resolve(application_proposal: ExecutionPolicy.restricted_id(), project_root: root)
    {:ok, binding} = Binding.build(source, pack, nil, policy, policy.workspace)
    binding
  end

  defp source_record(source, spec) do
    projection = Jidoka.project(spec)

    Record.build(
      base_spec: spec,
      identity: source.identity,
      kind: source.kind,
      format: source.format,
      byte_size: source.byte_size,
      digest: source.digest,
      base_spec_digest: Digest.semantic(:agent_base_spec, projection),
      agent_id: spec.id,
      label: source.label
    )
  end

  defp temporary_root(label) do
    root = Path.join(System.tmp_dir!(), "jido-thread-resources-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
