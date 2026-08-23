defmodule Jido.Console.Test.ThreadResources do
  @moduledoc false

  defstruct [:thread_id, :test_pid, :spec, :fail_resources?, :fail_once]

  def new(thread_id, _agent, opts) do
    spec =
      Jidoka.Agent.Spec.new!(
        id: "thread-test-agent",
        instructions: "Test one Console thread.",
        model: %{provider: :test, id: "model"}
      )

    {:ok,
     %__MODULE__{
       thread_id: thread_id,
       test_pid: Keyword.fetch!(opts, :test_pid),
       spec: spec,
       fail_resources?: Keyword.get(opts, :fail_resources, false),
       fail_once: Keyword.get(opts, :fail_resources_once)
     }}
  end

  def base_spec(resources), do: resources.spec

  def prepare(%__MODULE__{fail_resources?: true}, _session), do: {:error, :resource_setup_failed}

  def prepare(%__MODULE__{fail_once: counter} = resources, session) when is_pid(counter) do
    if Agent.get_and_update(counter, fn attempts -> {attempts, attempts + 1} end) == 0,
      do: {:error, :resource_setup_failed},
      else: {:ok, resources, session}
  end

  def prepare(resources, session), do: {:ok, resources, session}

  def prepare_prompt(resources, prompt, context) do
    send(resources.test_pid, {:resources_prepared, resources.thread_id, prompt})
    {:ok, prompt, context}
  end

  def runtime_opts(resources), do: [test_pid: resources.test_pid]
  def configure_model(resources, identity), do: {:ok, Map.put(resources, :model, identity)}
  def status(%__MODULE__{fail_resources?: true}), do: %{"status" => "not_prepared"}
  def status(%__MODULE__{}), do: %{"status" => "ready"}

  def close(resources) do
    send(resources.test_pid, {:resources_closed, resources.thread_id})
    :ok
  end
end

defmodule Jido.Console.Test.ThreadBridge do
  @moduledoc false

  def run(owner, run_ref, action) do
    Process.link(owner)

    if Map.get(action, :prompt) == "hold-link" do
      test_pid = Keyword.fetch!(action.runtime_opts, :test_pid)
      send(test_pid, {:bridge_waiting_to_link, self()})
      receive do: (:link_now -> :ok)
    end

    send(owner, {:bridge_linked, self(), run_ref})

    receive do
      {:begin, ^run_ref} ->
        test_pid = Keyword.fetch!(action.runtime_opts, :test_pid)
        send(test_pid, {:provider_started, action.thread_id, action.request_id, self()})
        finish(owner, run_ref, action)
    end
  end

  defp finish(_owner, _run_ref, %{prompt: "crash"}), do: exit(:provider_crash)

  defp finish(owner, run_ref, action) do
    receive do
      :finish ->
        send(owner, {:bridge_result, self(), run_ref, action.request_id, {:error, :test_complete}})

      {:finish, result} ->
        send(owner, {:bridge_result, self(), run_ref, action.request_id, result})

      {:emit, event} ->
        send(owner, {:bridge_event, run_ref, action.request_id, event})
        finish(owner, run_ref, action)
    end

    :ok
  end
end
