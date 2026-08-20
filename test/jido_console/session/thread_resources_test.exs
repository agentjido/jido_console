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
end
