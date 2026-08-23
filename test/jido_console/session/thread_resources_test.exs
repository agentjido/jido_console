defmodule Jido.Console.Session.ThreadResourcesTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Extensions.Setup, as: ExtensionSetup
  alias Jido.Console.Session.ThreadResources
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
             "profile_id" => nil
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

  defp session(resources) do
    {:ok, session} = Data.start(ThreadResources.base_spec(resources), session_id: resources.thread_id)
    session
  end
end
