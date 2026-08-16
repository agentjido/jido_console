defmodule Jido.Console.Automation.ReplayTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Jido.Console.Automation.Engine.Jidoka, as: JidokaEngine
  alias Jido.Console.Automation.{Loader, Plan, Result}
  alias Jido.Console.Automation.Replay
  alias Jidoka.Agent.Spec
  alias Jidoka.Replay.Capabilities, as: ReplayCapabilities
  alias Jidoka.Replay.Fixture
  alias Jidoka.Replay.Recorder
  alias Jidoka.Runtime.Capabilities

  defmodule ForbiddenEnvironmentAdapter do
    @behaviour Jidoka.ExecutionEnvironment.Adapter

    for {name, arity} <- [open: 3, acquire: 2, checkpoint: 3, restore: 3, fork: 3, close: 2, cleanup: 2] do
      @impl true
      def unquote(name)(unquote_splicing(Macro.generate_arguments(arity, __MODULE__))) do
        raise "live environment call #{unquote(name)} is forbidden during replay"
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "jido-cli-replay-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "loads only a pinned bounded fixture from trusted metadata", %{root: root} do
    fixture = fixture_for(cell(), final_capabilities("offline answer"))
    {:ok, json} = Fixture.encode_json(fixture)
    path = Path.join(root, "fixture.json")
    File.write!(path, json)

    assert {:ok, replay} = Replay.resolve(environment(path, fixture.digest))
    assert replay.mode == :replay
    assert replay.fixture.digest == fixture.digest
    projection = Replay.projection(replay)
    assert projection.mode == :replay
    assert projection.status == :configured
    refute inspect(projection) =~ path
    refute inspect(projection) =~ "entries"

    assert {:error, {:replay_fixture_digest_mismatch, _, _}} =
             Replay.resolve(environment(path, "sha256:" <> String.duplicate("0", 64)))

    assert {:error, {:replay_fixture_too_large, _, 10}} =
             Replay.resolve(environment(path, fixture.digest), max_replay_fixture_bytes: 10)

    assert {:error, {:unknown_replay_profile_keys, ["fixture_command"]}} =
             Replay.resolve(environment(path, fixture.digest, %{"fixture_command" => "read-it"}))

    assert {:error, :multiple_replay_fixture_sources} =
             Replay.resolve(environment(path, fixture.digest, %{"fixture_json" => json}))
  end

  test "replays the same multi-turn fixture in isolated concurrent cells without live calls" do
    fixture = fixture_for(cell(), multi_turn_capabilities())
    replay = replay_config(fixture)
    parent = self()

    cells =
      for index <- 1..2 do
        cell()
        |> Map.put(:run_id, "other-run-#{index}")
        |> Map.put(:cell_id, String.duplicate(Integer.to_string(index), 64))
        |> Map.put(:sequence, index)
        |> Map.put(:capability_replay, replay)
        |> Map.put(:runtime_opts,
          llm: fn _intent, _journal, _context ->
            send(parent, :live_llm_called)
            {:error, :live_call_forbidden}
          end
        )
      end

    results = cells |> Task.async_stream(&run(&1, []), ordered: false) |> Enum.map(&elem(&1, 1))

    assert Enum.all?(results, &(&1.execution.status == :ok))
    assert Enum.all?(results, &(&1.capability_replay.status == :matched))
    assert Enum.all?(results, &(&1.capability_replay.fixture_digest == fixture.digest))
    assert Enum.all?(results, &(&1.capability_replay.matched_calls == length(fixture.entries)))
    assert Enum.all?(results, &(Enum.map(&1.turns, fn turn -> turn.response.content end) == ["Stored", "Recalled"]))
    refute_receive :live_llm_called
  end

  test "a changed call and an unused entry give bounded mismatch evidence" do
    fixture = fixture_for(cell(), multi_turn_capabilities())

    changed =
      cell()
      |> put_in([:scenario, :turns, Access.at(0), :input], "Changed semantic input")
      |> Map.put(:capability_replay, replay_config(fixture))

    changed_result = run(changed, [])
    assert changed_result.execution.status == :error
    assert changed_result.execution.turn_count == length(changed_result.turns)
    assert changed_result.evaluation.status == :not_run
    assert changed_result.usage == Result.usage(changed_result.turns)
    assert changed_result.capability_replay.status == :mismatch
    assert changed_result.capability_replay.mismatch.kind == :changed_or_out_of_order
    refute inspect(changed_result.capability_replay.mismatch) =~ "fingerprint"

    {:ok, recorder} = Recorder.start_recording()
    assert {:ok, :extra} = Recorder.capture(recorder, :llm, :extra, %{}, fn -> {:ok, :extra} end)
    {:ok, extra_fixture} = Recorder.fixture(recorder)
    [extra_entry] = extra_fixture.entries
    extra_entry = %{extra_entry | index: length(fixture.entries) + 1}
    {:ok, fixture_with_extra} = Fixture.new(%{entries: fixture.entries ++ [extra_entry]})

    extra_result = run(Map.put(cell(), :capability_replay, replay_config(fixture_with_extra)), [])
    assert extra_result.execution.status == :error
    assert extra_result.capability_replay.status == :mismatch
    assert extra_result.capability_replay.mismatch.kind == :extra_calls
  end

  test "a recorded provider error stays a matched replay outcome" do
    fixture = fixture_for(one_turn_cell(), Capabilities.new!(llm: fn _, _, _ -> {:error, :provider_offline} end))
    result = run(Map.put(one_turn_cell(), :capability_replay, replay_config(fixture)), [])

    assert result.execution.status == :error
    assert result.capability_replay.status == :matched
    assert result.capability_replay.matched_calls == length(fixture.entries)
  end

  test "external cancellation keeps cancellation evidence when fixture entries remain" do
    fixture = fixture_for(one_turn_cell(), final_capabilities("unused"))
    replay = replay_config(fixture)
    {:ok, player} = Replay.open(replay)

    result =
      Result.new(one_turn_cell(),
        execution: %{
          status: :cancelled,
          started_at: "2026-01-01T00:00:00Z",
          duration_ms: 1
        },
        turns: [],
        error: Result.error(:cancelled),
        extensions: %{}
      )

    finalized = Replay.finalize(result, replay, player)
    assert finalized.execution.status == :cancelled
    assert finalized.capability_replay.status == :cancelled
    assert finalized.capability_replay.matched_calls == 0
    refute Map.has_key?(finalized.capability_replay, :mismatch)
  end

  test "runs a concurrent offline suite with matching manifest and result evidence", %{root: root} do
    %{suite: suite_path, scenario: scenario_path} = write_offline_suite(root)
    fixture = fixture_for_suite(suite_path)
    fixture_path = Path.join(root, "offline.fixture.json")
    {:ok, fixture_json} = Fixture.encode_json(fixture)
    File.write!(fixture_path, fixture_json)
    resolver = profile_resolver(fixture_path, fixture.digest)
    output = Path.join(root, "offline-output")
    {:ok, stdout} = StringIO.open("")
    parent = self()

    live_llm = fn _intent, _journal, _context ->
      send(parent, :offline_live_llm_called)
      {:error, :live_provider_forbidden}
    end

    assert :ok =
             Jido.Console.run(
               ["eval", suite_path, "--output", output],
               execution_profile_resolver: resolver,
               runtime_opts: [llm: live_llm],
               output_device: stdout,
               run_id: "offline-run"
             )

    {_input, text} = StringIO.contents(stdout)
    records = text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert length(records) == 2

    assert Enum.all?(records, fn record ->
             record["capability_replay"]["mode"] == "replay" and
               record["capability_replay"]["status"] == "matched" and
               record["capability_replay"]["fixture_digest"] == fixture.digest and
               record["execution_environment"]["status"] == "recorded"
           end)

    refute text =~ fixture_path
    refute text =~ "entries"
    refute_receive :offline_live_llm_called

    manifest = output |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()

    assert Enum.all?(manifest["cells"], fn cell ->
             cell["capability_replay"]["mode"] == "replay" and
               cell["capability_replay"]["fixture_digest"] == fixture.digest
           end)

    File.write!(scenario_path, String.replace(File.read!(scenario_path), "Remember", "Changed"))
    mismatch_output = Path.join(root, "mismatch-output")
    {:ok, mismatch_stdout} = StringIO.open("")

    mismatch_diagnostic =
      capture_io(:stderr, fn ->
        assert {:error, 1} =
                 Jido.Console.run(
                   ["eval", suite_path, "--output", mismatch_output],
                   execution_profile_resolver: resolver,
                   runtime_opts: [llm: live_llm],
                   output_device: mismatch_stdout,
                   run_id: "mismatch-run"
                 )
      end)

    assert mismatch_diagnostic =~ "automated run failed"

    {_input, mismatch_text} = StringIO.contents(mismatch_stdout)

    assert mismatch_text
           |> String.split("\n", trim: true)
           |> Enum.map(&Jason.decode!/1)
           |> Enum.all?(&(&1["capability_replay"]["status"] == "mismatch"))

    bad_output = Path.join(root, "bad-output")
    bad_resolver = profile_resolver(fixture_path, "sha256:" <> String.duplicate("0", 64))

    invalid_fixture_diagnostic =
      capture_io(:stderr, fn ->
        assert {:error, 64} =
                 Jido.Console.run(
                   ["eval", suite_path, "--output", bad_output],
                   execution_profile_resolver: bad_resolver,
                   output_device: stdout
                 )
      end)

    assert invalid_fixture_diagnostic =~ "replay_fixture_digest_mismatch"

    refute File.exists?(bad_output)
  end

  test "the committed offline release fixture runs without a provider capability" do
    fixture_path = "priv/release/offline_fixture.json"
    {:ok, fixture} = fixture_path |> File.read!() |> Fixture.decode_json()
    resolver = profile_resolver(Path.expand(fixture_path), fixture.digest)
    {:ok, stdout} = StringIO.open("")
    parent = self()

    assert :ok =
             Jido.Console.run(
               ["eval", "release/fixtures/offline/suite.yml"],
               execution_profile_resolver: resolver,
               runtime_opts: [
                 llm: fn _intent, _journal, _context ->
                   send(parent, :example_live_provider_called)
                   {:error, :forbidden}
                 end
               ],
               output_device: stdout,
               run_id: "offline-example"
             )

    {_input, text} = StringIO.contents(stdout)
    assert [record] = text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert record["capability_replay"]["status"] == "matched"
    assert record["evaluation"]["status"] == "passed"
    refute_receive :example_live_provider_called
  end

  test "rejects malformed replay profiles and accepts an inline fixture", %{root: root} do
    fixture = fixture_for(cell(), final_capabilities("inline"))
    {:ok, json} = Fixture.encode_json(fixture)
    directory = Path.join(root, "fixture-directory")
    File.mkdir_p!(directory)

    assert {:ok, %{mode: :live}} = Replay.resolve(nil)
    assert {:error, :invalid_replay_profile_environment} = Replay.resolve(:invalid)
    assert :ok = Replay.stop(nil)

    assert {:error, {:invalid_replay_profile, 42}} =
             Replay.resolve(%{registration: %{metadata: %{"jido_console.replay" => 42}}})

    invalid_profiles = [
      {%{"mode" => "live"}, {:invalid_replay_profile_mode, "live"}},
      {%{"mode" => nil}, {:invalid_replay_profile_mode, nil}},
      {%{"mode" => "replay"}, :missing_replay_fixture_source},
      {%{"mode" => "replay", "max_bytes" => 0}, {:invalid_replay_fixture_limit, 0}},
      {%{"mode" => "replay", "fixture_path" => directory}, :replay_fixture_not_regular},
      {%{"mode" => "replay", "fixture_path" => Path.join(root, "missing")}, {:replay_fixture_unavailable, :enoent}},
      {%{"mode" => "replay", "fixture_json" => json, "fixture_digest" => 42}, {:invalid_replay_fixture_digest, 42}},
      {%{"mode" => "replay", "fixture_json" => json, "fixture_digest" => "bad"},
       {:invalid_replay_fixture_digest, "digest must use an immutable sha256 value"}},
      {%{
         "mode" => "replay",
         "fixture_json" => json,
         "fixture_digest" => fixture.digest,
         "compatibility" => "bad"
       }, {:invalid_replay_compatibility, "bad"}}
    ]

    for {metadata, expected} <- invalid_profiles do
      environment = %{registration: %{metadata: %{"jido_console.replay" => metadata}}}
      assert {:error, ^expected} = Replay.resolve(environment)
    end

    unsafe = %{
      "mode" => "replay",
      "fixture_json" => json,
      "fixture_digest" => fixture.digest,
      "compatibility" => %{"token" => "secret"}
    }

    assert {:error, {:invalid_replay_compatibility, _reason}} =
             Replay.resolve(%{registration: %{metadata: %{"jido_console.replay" => unsafe}}})

    inline = %{
      "mode" => "replay",
      "fixture_json" => json,
      "fixture_digest" => fixture.digest,
      "compatibility" => nil
    }

    assert {:ok, replay} = Replay.resolve(%{registration: %{metadata: %{jido_console_replay: inline}}})
    assert {:ok, player} = Replay.open(replay)
    assert Replay.put_runtime([keep: true], player)[:capabilities]
    assert :ok = Replay.stop(player)
    assert :ok = Replay.stop(player)
  end

  test "finds portable missing and extra call mismatch forms" do
    fixture = fixture_for(one_turn_cell(), final_capabilities("unused"))
    replay = replay_config(fixture)

    errors = [
      {:capability_replay_missing_call, :invalid_summary},
      ["capability_replay_missing_call", %{"class" => "llm", "action" => "call"}],
      ["capability_replay_extra_calls", 1, 1]
    ]

    for error <- errors do
      {:ok, player} = Replay.open(replay)

      result =
        Result.new(one_turn_cell(),
          execution: %{status: :error, started_at: "2026-01-01T00:00:00Z", duration_ms: 1},
          turns: [],
          error: Result.error(:fixture),
          extensions: %{}
        )
        |> Map.put(:error, error)

      finalized = Replay.finalize(result, replay, player)
      assert finalized.execution.status == :error
      assert finalized.capability_replay.status == :mismatch
      assert finalized.capability_replay.mismatch.kind in [:missing_call, :extra_calls]
    end
  end

  defp fixture_for(cell, capabilities) do
    {:ok, recorder} = Recorder.start_recording()
    recorded = ReplayCapabilities.record(capabilities, recorder)

    result =
      cell
      |> Map.put(:runtime_opts, capabilities: recorded)
      |> run([])

    assert result.capability_replay.mode == :live
    {:ok, fixture} = Recorder.fixture(recorder)
    fixture
  end

  defp replay_config(fixture) do
    %{mode: :replay, fixture: fixture, compatibility: %{}}
  end

  defp final_capabilities(content) do
    Capabilities.new!(llm: fn _intent, _journal, _context -> {:ok, %{type: :final, content: content}} end)
  end

  defp multi_turn_capabilities do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Capabilities.new!(
      llm: fn _intent, _journal, _context ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:ok, %{type: :final, content: "Stored"}}
          1 -> {:ok, %{type: :final, content: "Recalled"}}
        end
      end
    )
  end

  defp cell do
    spec =
      Spec.new!(
        id: "replay_agent",
        model: "openai:gpt-4o-mini",
        instructions: "Keep turn state."
      )

    %{
      run_id: "record-run",
      cell_id: String.duplicate("a", 64),
      sequence: 1,
      dimensions: %{
        suite_id: "replay",
        agent_key: "agent",
        agent_spec_id: spec.id,
        scenario_id: "memory",
        model_key: "declared",
        model_ref: "openai:gpt-4o-mini",
        trial: 1
      },
      sources: %{
        agent_file: "agent.yml",
        scenario_file: "scenario.yml",
        agent_sha256: "agent-sha",
        effective_agent_sha256: "effective-agent-sha",
        scenario_sha256: "scenario-sha"
      },
      spec: spec,
      runtime_opts: [],
      execution_environment: nil,
      scenario: %{
        turns: [
          %{id: "store", input: "Store", context: %{}, assertions: %{}},
          %{id: "recall", input: "Recall", context: %{}, assertions: %{}}
        ]
      }
    }
  end

  defp one_turn_cell do
    put_in(cell(), [:scenario, :turns], [%{id: "one", input: "One", context: %{}, assertions: %{}}])
  end

  defp environment(path, digest, extra \\ %{}) do
    config =
      Map.merge(
        %{
          "mode" => "replay",
          "fixture_path" => path,
          "fixture_digest" => digest,
          "compatibility" => %{}
        },
        extra
      )

    %{registration: %{metadata: %{"jido_console.replay" => config}}}
  end

  defp write_offline_suite(root) do
    agent = Path.join(root, "agent.yml")
    scenario = Path.join(root, "scenario.yml")
    suite = Path.join(root, "suite.yml")

    File.write!(agent, """
    version: 1
    agent:
      id: offline_agent
      model: openai:gpt-4o-mini
      instructions: Remember facts between turns.
      execution_profile: offline
    """)

    File.write!(scenario, """
    version: 1
    scenario:
      id: offline_memory
      turns:
        - id: store
          input: Remember Atlas.
          assertions:
            contains: Stored
        - id: recall
          input: Recall the value.
          assertions:
            equals: Recalled
    """)

    File.write!(suite, """
    version: 1
    suite:
      id: offline_suite
      agents:
        - key: offline
          file: agent.yml
      scenarios:
        - scenario.yml
      models:
        - key: declared
          source: agent
      matrix:
        repeats: 2
      run:
        jobs: 2
    """)

    %{agent: agent, scenario: scenario, suite: suite}
  end

  defp fixture_for_suite(suite_path) do
    assert {:ok, suite} = Loader.load_suite(suite_path)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    capabilities =
      Capabilities.new!(
        llm: fn _intent, _journal, _context ->
          case Agent.get_and_update(calls, &{&1, &1 + 1}) do
            0 -> {:ok, %{type: :final, content: "Stored"}}
            1 -> {:ok, %{type: :final, content: "Recalled"}}
          end
        end
      )

    {:ok, recorder} = Recorder.start_recording()
    recorded = ReplayCapabilities.record(capabilities, recorder)

    assert {:ok, plan} =
             Plan.build(suite,
               execution_profile_resolver: profile_resolver(nil, nil),
               runtime_opts: [capabilities: recorded],
               run_id: "fixture-run"
             )

    first = plan.cells |> hd() |> Map.put(:execution_environment, nil) |> Map.put(:capability_replay, %{mode: :live})
    assert run(first, []).execution.status == :ok
    assert {:ok, fixture} = Recorder.fixture(recorder)
    fixture
  end

  defp profile_resolver(path, digest) do
    fn profile_id, _opts ->
      metadata =
        if path do
          %{
            "jido_console.replay" => %{
              "mode" => "replay",
              "fixture_path" => path,
              "fixture_digest" => digest,
              "compatibility" => %{}
            }
          }
        else
          %{}
        end

      {:ok, registration(profile_id, metadata)}
    end
  end

  defp registration(profile_id, metadata) do
    profile =
      Jidoka.ExecutionEnvironment.SecurityProfile.new!(
        profile_id: profile_id,
        revision: 1,
        digest: "sha256:" <> String.duplicate("a", 64),
        adapter_id: "test.replay",
        required_isolation: :container,
        required_network: :disabled,
        required_workspace: :ephemeral
      )

    capabilities =
      Jidoka.ExecutionEnvironment.AdapterCapabilities.new!(
        adapter_id: "test.replay",
        adapter_version: "1",
        isolations: [:container],
        networks: [:disabled],
        workspaces: [:ephemeral]
      )

    Jidoka.ExecutionEnvironment.Registration.new!(
      profile: profile,
      adapter: ForbiddenEnvironmentAdapter,
      capabilities: capabilities,
      metadata: metadata
    )
  end

  defp run(cell, opts), do: Jido.Console.Automation.Engine.run(JidokaEngine, cell, opts)
end
