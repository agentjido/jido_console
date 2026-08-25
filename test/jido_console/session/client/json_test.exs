defmodule Jido.Console.Session.Client.JSONTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.Client.JSON
  alias Jido.Console.Session.{Registry, Supervisor, View}
  alias Jido.Console.Storage.Supervisor, as: StorageSupervisor
  alias Jido.Console.Test.{ThreadBridge, ThreadResources}

  setup do
    suffix = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "jido-json-client-#{suffix}")
    writer = unique(:writer, suffix)
    registry = unique(:registry, suffix)
    sessions = unique(:sessions, suffix)
    tasks = unique(:tasks, suffix)

    {:ok, storage} =
      StorageSupervisor.start_link(
        name: unique(:storage_supervisor, suffix),
        writer: writer,
        lock: unique(:lock, suffix),
        jido_home: root
      )

    {:ok, supervisor} =
      Supervisor.start_link(
        name: unique(:session_supervisor, suffix),
        registry: registry,
        sessions: sessions,
        tasks: tasks
      )

    opts = [
      registry: registry,
      supervisor: sessions,
      tasks: tasks,
      writer: writer,
      deadline: 5_000,
      resources_module: ThreadResources,
      bridge_module: ThreadBridge,
      test_pid: self()
    ]

    on_exit(fn ->
      if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
      if Process.alive?(storage), do: Process.exit(storage, :shutdown)
      File.rm_rf(root)
    end)

    %{opts: opts}
  end

  test "runs the full idle client API and writes only JSONL", %{opts: opts} do
    records =
      run_json(
        [
          input("attach", "attach", "full-api"),
          input("cancel", "cancel", "full-api", %{"request_id" => "missing"}),
          input("approve", "approve", "full-api", %{"request_id" => "request", "review_id" => "review"}),
          input("deny", "deny", "full-api", %{"request_id" => "request", "review_id" => "review"}),
          input("remove", "remove", "full-api", %{"queue_item_id" => "missing"}),
          input("model", "select_model", "full-api", %{"identity" => "ollama:llama3.2"}),
          input("status", "status", "full-api"),
          input("history", "history", "full-api", %{"limit" => 10}),
          input("stop", "stop", "full-api")
        ],
        opts
      )

    results = Enum.filter(records, &(&1["type"] == "result"))
    assert Enum.map(results, & &1["id"]) == ~w(attach cancel approve deny remove model status history stop)
    assert Enum.find(results, &(&1["id"] == "cancel"))["ok"] == false
    assert Enum.find(results, &(&1["id"] == "remove"))["data"]["status"] == "removed"
    assert Enum.find(results, &(&1["id"] == "model"))["data"]["identity"] == "ollama:llama3.2"
    assert Enum.find(results, &(&1["id"] == "history"))["data"]["events"] == []
    assert Enum.find(results, &(&1["id"] == "stop"))["data"]["status"] == "stopped"

    assert Enum.any?(records, fn record ->
             record["type"] == "view" and record["thread_id"] == "full-api" and
               record["view"]["status"] == "idle"
           end)
  end

  test "reattaches and detaches with new portable attachment identity", %{opts: opts} do
    records =
      run_json(
        [
          input("attach", "attach", "lifecycle"),
          input("reattach", "reattach", "lifecycle"),
          input("detach", "detach", "lifecycle")
        ],
        opts
      )

    attach = find_result(records, "attach")
    reattach = find_result(records, "reattach")
    assert attach["data"]["attachment_id"] == "attachment-0"
    assert reattach["data"]["attachment_id"] == "attachment-1"
    assert reattach["data"]["previous_attachment_id"] == "attachment-0"
    assert find_result(records, "detach")["data"]["status"] == "detached"
  end

  test "continues after malformed input and enforces the attachment limit", %{opts: opts} do
    records =
      run_json(
        [
          "not json",
          input("first", "attach", "first"),
          input("second", "attach", "second"),
          input("detach", "detach", "first")
        ],
        opts,
        max_threads: 1
      )

    assert Enum.at(records, 0)["ok"] == false
    assert Enum.at(records, 0)["id"] == nil
    assert find_result(records, "first")["ok"]
    assert find_result(records, "second")["error"]["code"] == "too_many_attachments"
    assert find_result(records, "detach")["ok"]
  end

  test "discards one oversized line and continues with the next command", %{opts: opts} do
    oversized = String.duplicate("x", 10_000)

    records =
      run_json(
        [
          oversized,
          input("attach", "attach", "after-large-line"),
          input("detach", "detach", "after-large-line")
        ],
        opts,
        max_record_bytes: 8_192
      )

    assert Enum.at(records, 0)["error"]["code"] == "input_too_large"
    assert find_result(records, "attach")["ok"]
    assert find_result(records, "detach")["ok"]
  end

  test "a blocked writer receives one gap and the latest complete view", %{opts: opts} do
    {:ok, input_device} =
      StringIO.open(Jason.encode!(input("attach", "attach", "slow-output")) <> "\n")

    {:ok, output_device} = StringIO.open("")
    test_pid = self()
    {:ok, writes} = Agent.start_link(fn -> 0 end)

    write_fun = fn device, encoded ->
      index = Agent.get_and_update(writes, fn value -> {value, value + 1} end)

      if index == 0 do
        send(test_pid, {:json_writer_blocked, self()})

        receive do
          :release_json_writer -> :ok
        end
      end

      IO.binwrite(device, encoded)
    end

    task =
      Task.async(fn ->
        JSON.run(
          input_device: input_device,
          output_device: output_device,
          session_options: opts,
          id_generator: fn _prefix -> "attachment-slow" end,
          write_fun: write_fun
        )
      end)

    assert_receive {:json_writer_blocked, writer}, 2_000
    assert {:ok, owner} = Registry.lookup("slow-output", opts[:registry])
    [{attachment_ref, %{pid: attachment}}] = Map.to_list(:sys.get_state(owner).subscribers)

    for revision <- 1..5 do
      send(
        attachment,
        {:jido_console_view, attachment_ref, View.new!(thread_id: "slow-output", status: :running, revision: revision)}
      )
    end

    send(writer, :release_json_writer)
    assert :ok = Task.await(task, 5_000)
    {_input, output} = StringIO.contents(output_device)
    records = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    gap = Enum.find(records, &(&1["type"] == "gap"))
    assert gap["from_revision"] == 1
    assert gap["through_revision"] == 4

    latest = records |> Enum.filter(&(&1["type"] == "view")) |> List.last()
    assert latest["view"]["revision"] == 5
  end

  test "retries one stable submit without a second provider call and leaves work running after EOF", %{opts: opts} do
    inputs = [
      input("attach", "attach", "submit-thread"),
      input("prompt-1", "submit", "submit-thread", %{"request_id" => "request-1", "text" => "hold"}),
      input("prompt-1", "submit", "submit-thread", %{"request_id" => "request-1", "text" => "hold"})
    ]

    task = Task.async(fn -> run_json(inputs, opts) end)
    records = Task.await(task, 5_000)

    prompt_results = Enum.filter(records, &(&1["id"] == "prompt-1"))
    assert Enum.map(prompt_results, & &1["data"]["duplicate"]) == [false, true]
    assert_receive {:provider_started, "submit-thread", "request-1", bridge}, 2_000
    refute_receive {:provider_started, "submit-thread", "request-1", _other}, 50
    assert Process.alive?(bridge)
    send(bridge, :finish)
  end

  test "two attached threads run work independently", %{opts: opts} do
    inputs = [
      input("attach-a", "attach", "parallel-a"),
      input("attach-b", "attach", "parallel-b"),
      input("prompt-a", "submit", "parallel-a", %{"request_id" => "request-a", "text" => "hold"}),
      input("prompt-b", "submit", "parallel-b", %{"request_id" => "request-b", "text" => "hold"})
    ]

    records = Task.async(fn -> run_json(inputs, opts) end) |> Task.await(5_000)

    assert find_result(records, "prompt-a")["ok"]
    assert find_result(records, "prompt-b")["ok"]
    assert_receive {:provider_started, "parallel-a", "request-a", first_bridge}, 2_000
    assert_receive {:provider_started, "parallel-b", "request-b", second_bridge}, 2_000
    assert Process.alive?(first_bridge)
    assert Process.alive?(second_bridge)

    send(first_bridge, :finish)
    send(second_bridge, :finish)
  end

  test "a writer failure detaches the JSON attachment", %{opts: opts} do
    input_text = Jason.encode!(input("attach", "attach", "writer-failure")) <> "\n"
    {:ok, input_device} = StringIO.open(input_text)
    {:ok, output_device} = StringIO.open("")

    assert {:error, {:output_failed, :closed}} =
             JSON.run(
               input_device: input_device,
               output_device: output_device,
               session_options: opts,
               write_fun: fn _device, _encoded -> {:error, :closed} end
             )

    assert {:ok, owner} = Registry.lookup("writer-failure", opts[:registry])
    assert :sys.get_state(owner).subscribers == %{}
  end

  defp run_json(inputs, session_options, json_options \\ []) do
    input_text = Enum.map_join(inputs, "\n", &encode_input/1) <> "\n"
    {:ok, input_device} = StringIO.open(input_text)
    {:ok, output_device} = StringIO.open("")
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    id_generator = fn prefix ->
      index = Agent.get_and_update(counter, fn value -> {value, value + 1} end)
      "#{prefix}-#{index}"
    end

    assert :ok =
             JSON.run(
               Keyword.merge(json_options,
                 input_device: input_device,
                 output_device: output_device,
                 session_options: session_options,
                 id_generator: id_generator
               )
             )

    {_input, output} = StringIO.contents(output_device)

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp encode_input(input) when is_binary(input), do: input
  defp encode_input(input), do: Jason.encode!(input)

  defp input(id, type, thread_id, fields \\ %{}) do
    Map.merge(
      %{"version" => 1, "id" => id, "type" => type, "thread_id" => thread_id},
      fields
    )
  end

  defp find_result(records, id), do: Enum.find(records, &(&1["type"] == "result" and &1["id"] == id))
  defp unique(label, suffix), do: String.to_atom("#{label}-#{suffix}")
end
