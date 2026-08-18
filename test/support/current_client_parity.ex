defmodule Jido.Console.TestSupport.CurrentClientParity do
  @moduledoc "Provider-free production-path parity support for M2-E31."

  alias Jido.Console.Runtime.Result
  alias Jido.Console.Session.Client
  alias Jido.Console.Session.Client.{Automation, JSON, Text, TUI}
  alias Jido.Console.Session.Supervisor
  alias Jido.Console.Tui.{State, Turn, View}
  alias Jidoka.Event

  @fixture_path "test/fixtures/session/current_client_parity_v1.json"
  @surfaces [:tui, :automation, :text, :json]

  defmodule Runtime do
    @moduledoc false

    @behaviour Jido.Console.Runtime

    alias Jido.Console.Runtime.Result
    alias Jidoka.Event

    @impl true
    def start_session(_agent, opts), do: {:ok, Keyword.fetch!(opts, :parity_fixture)}

    @impl true
    def start_turn(fixture, prompt, owner, _opts) do
      request_id = fixture["request_id"]
      tool = fixture["tool"]

      events = [
        Event.build(:effect_started, [],
          request_id: request_id,
          seq: 0,
          effect_id: tool["id"],
          effect_kind: :operation,
          operation: tool["operation"]
        ),
        Event.build(:effect_completed, [],
          request_id: request_id,
          seq: 1,
          effect_id: tool["id"],
          effect_kind: :operation,
          operation: tool["operation"],
          data: %{content: fixture["content"]}
        ),
        Event.build(:llm_delta, [],
          request_id: request_id,
          seq: 2,
          data: %{chunk_type: :content, delta: fixture["content"]}
        )
      ]

      Enum.each(events, &send(owner, {:jidoka_turn_event, &1}))
      send(owner, {:jidoka_turn_event, Event.build(:turn_finished, events, request_id: request_id, seq: 3)})

      {:ok, %{request_id: request_id, prompt: prompt, fixture: fixture}}
    end

    @impl true
    def await(request, _opts) do
      review = %{
        interrupt_id: request.fixture["approval_id"],
        operation: request.fixture["tool"]["operation"],
        arguments: %{"content" => request.fixture["content"]},
        reason: :fixture_permission,
        expires_at_ms: 30_000
      }

      Result.pending_review(request.request_id, request.fixture["session_id"], request, [review])
    end

    @impl true
    def approve(%Result{} = pending, _review, _opts) do
      Result.ok(pending.request_id, pending.session, pending.handle, pending.handle.fixture["content"],
        approval: :approved
      )
    end

    @impl true
    def deny(%Result{} = pending, _review, _opts) do
      Result.error(pending.request_id, pending.session, pending.handle, :permission_denied, approval: :denied)
    end

    @impl true
    def cancel(_request, _opts), do: {:error, :not_supported}
  end

  defmodule TerminalAdapter do
    @moduledoc false

    @behaviour Jido.Console.Terminal.Adapter

    @impl true
    def open(owner, opts) do
      ref = make_ref()
      test_pid = Keyword.fetch!(opts, :test_pid)
      size = Keyword.get(opts, :size, {80, 24})
      send(test_pid, {:parity_terminal_opened, owner, ref})
      {:ok, %{test_pid: test_pid, size: size}, ref, size}
    end

    @impl true
    def write(handle, output) do
      send(handle.test_pid, {:parity_frame, IO.iodata_to_binary(output)})
      :ok
    end

    @impl true
    def size(handle), do: {:ok, handle.size}

    @impl true
    def close(handle) do
      send(handle.test_pid, :parity_terminal_closed)
      :ok
    end
  end

  defmodule ForbiddenEnvironmentAdapter do
    @moduledoc false

    @behaviour Jidoka.ExecutionEnvironment.Adapter

    for {name, arity} <- [open: 3, acquire: 2, checkpoint: 3, restore: 3, fork: 3, close: 2, cleanup: 2] do
      @impl true
      def unquote(name)(unquote_splicing(Macro.generate_arguments(arity, __MODULE__))) do
        raise "live execution environment is forbidden in the parity corpus"
      end
    end
  end

  @spec fixture!() :: map()
  def fixture! do
    @fixture_path
    |> File.read!()
    |> Jason.decode!()
  end

  @spec surfaces() :: [atom()]
  def surfaces, do: @surfaces

  @spec run_surface!(atom(), map()) :: map()
  def run_surface!(surface, fixture) when surface in @surfaces do
    %{handle: handle, snapshot: snapshot} = attach!(surface, fixture)

    :ok = Client.configure_runtime(handle, Runtime, :parity_agent, parity_fixture: fixture)
    {:ok, request} = Client.start_turn(handle, fixture["prompt"])

    state = tui_state(surface, snapshot, fixture, request)
    %Result{outcome: %Result.PendingReview{reviews: [review | _reviews]}} = Client.await(handle, request)
    {:ok, :requested} = Client.approve(handle, request, review)
    %Result{outcome: %Result.Ok{}} = Client.await(handle, request)
    {events, state} = collect_output!(surface, handle, state, [])
    :ok = Client.detach(handle)

    ledger = normalize(events)

    %{
      surface: surface,
      ledger: ledger,
      fingerprint: fingerprint(ledger),
      renderer: render(surface, events, state),
      side_effects: side_effects(ledger)
    }
  end

  @spec lifecycle_surface!(atom(), map()) :: map()
  def lifecycle_surface!(surface, fixture) when surface in @surfaces do
    %{handle: handle} = attach!(surface, fixture, delivery_limits: %{queue_count: 1})

    {:ok, _first} = Client.send(handle, "first")
    {:ok, _second} = Client.send(handle, "second")
    {:gap, gap} = Client.output(handle)
    {:ok, snapshot} = Client.recover(handle, gap)
    {:error, :delivery_recovering} = Client.output(handle)
    {:ok, suffix} = Client.replay(handle, snapshot["payload"]["recovery_token"])
    stale = Client.resume(handle, "stale")
    {:ok, receipt} = Client.resume(handle, suffix["payload"]["completion_token"])
    :ok = Client.detach(handle)
    detached = Client.status(handle)

    %{
      gap: gap["type"],
      recovery: snapshot["type"],
      suffix: suffix["type"],
      stale_completion: stale,
      receipt: receipt["type"],
      detached: detached
    }
  end

  @spec control_surface!(atom(), map()) :: map()
  def control_surface!(surface, fixture) when surface in @surfaces do
    %{handle: handle} = attach!(surface, fixture)
    request_id = "parity-cancel-request-v1"
    {:ok, await_worker} = Agent.start_link(fn -> nil end)

    spec = [
      start: fn _owner -> {:ok, %{request_id: request_id}} end,
      await: fn _request ->
        worker = self()
        Agent.update(await_worker, fn _pid -> worker end)

        receive do
          {:parity_cancelled, cancellation} ->
            Result.cancelled(request_id, fixture["session_id"], :fixture, cancellation)
        end
      end,
      cancel: fn _request, _opts ->
        cancellation = Jidoka.Cancellation.new!(request_id: request_id, cancelled_at_ms: 0)
        worker = await_agent_value!(await_worker)
        send(worker, {:parity_cancelled, cancellation})
        {:ok, cancellation}
      end,
      request_id: request_id,
      run_id: "parity-cancel-run-v1",
      prompt: "Cancel this fixture."
    ]

    {:ok, request} = Client.start_operation(handle, spec)
    {:ok, %Jidoka.Cancellation{}} = Client.cancel_and_wait(handle, request, [], 1_000)
    %Result{outcome: %Result.Cancelled{}} = Client.await(handle, request, 1_000)
    events = collect_raw_output!(handle, [])
    :ok = Client.detach(handle)
    Agent.stop(await_worker)
    ledger = normalize(events)

    %{
      types: Enum.map(ledger, & &1["type"]),
      control:
        ledger
        |> Enum.find(&(&1["type"] == "control_completed"))
        |> get_in(["payload", "result", "status"]),
      terminal:
        ledger
        |> Enum.find(&(&1["type"] == "run_failed"))
        |> get_in(["payload", "reason"])
    }
  end

  @spec run_tui_entry!(map()) :: String.t()
  def run_tui_entry!(fixture) do
    test_pid = self()

    task =
      Task.async(fn ->
        Jido.Console.Tui.run(
          runtime: Runtime,
          runtime_startup: fn -> :ok end,
          coding_pack: :disabled,
          session_id: fixture["session_id"] <> "-entry",
          session_opts: [parity_fixture: fixture],
          terminal_adapter: TerminalAdapter,
          terminal_adapter_opts: [test_pid: test_pid, size: {80, 24}]
        )
      end)

    {owner, ref} = await_terminal_open!()
    _initial = await_frame!(["idle · Enter sends"], 10_000)
    send(owner, {:jido_terminal, ref, {:text, fixture["prompt"]}})
    send(owner, {:jido_terminal, ref, {:key, :enter}})
    _review = await_frame!(["Review required", fixture["tool"]["operation"]], 5_000)
    send(owner, {:jido_terminal, ref, {:text, "a"}})
    frame = await_frame!([fixture["content"], fixture["tool"]["operation"], "idle · Enter sends"], 5_000)
    send(owner, {:jido_terminal, ref, {:key, :escape}})

    :ok = Task.await(task, 5_000)
    receive_exact!(:parity_terminal_closed, 1_000)
    frame
  end

  @spec run_automation_paths!(map()) :: map()
  def run_automation_paths!(fixture) do
    automation = fixture["automation"]
    fixture_path = Path.expand(automation["replay_fixture"])
    {:ok, replay} = fixture_path |> File.read!() |> Jidoka.Replay.Fixture.decode_json()

    if replay.digest != automation["replay_digest"] do
      raise "parity replay digest mismatch"
    end

    resolver = profile_resolver(fixture_path, replay.digest)
    root = Path.join(System.tmp_dir!(), "jido-parity-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)

    eval =
      run_automation!(
        ["eval", automation["suite"], "--output", Path.join(root, "eval")],
        resolver,
        Path.join(root, "eval")
      )

    run =
      run_automation!(
        [
          "run",
          "--agent",
          automation["agent"],
          "--scenario",
          automation["scenario"],
          "--output",
          Path.join(root, "run")
        ],
        resolver,
        Path.join(root, "run")
      )

    receive do
      :parity_live_provider_called -> raise "parity corpus called a live provider"
    after
      0 -> :ok
    end

    %{eval: eval, run: run}
  end

  @spec fingerprint([map()]) :: String.t()
  def fingerprint(ledger) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(ledger, [:deterministic]))
    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  defp attach!(surface, fixture, extra_opts \\ []) do
    suffix = System.unique_integer([:positive, :monotonic])
    names = names("parity-#{surface}", suffix)
    storage_opts = Keyword.put(names, :name, names[:storage])
    {:ok, storage} = Jido.Console.Storage.Supervisor.start_link(storage_opts)
    {:ok, supervisor} = Supervisor.start_link(names)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
      if Process.alive?(storage), do: Process.exit(storage, :shutdown)
    end)

    opts =
      [
        registry: names[:registry],
        supervisor: names[:sessions],
        tasks: names[:tasks],
        writer: names[:writer],
        quota: names[:quota],
        admission: names[:admission],
        client_id: "parity-#{surface}-v1"
      ] ++
        extra_opts

    case surface do
      :tui ->
        {:ok, attached} = TUI.attach(fixture["session_id"], opts)
        attached

      :automation ->
        {:ok, handle} = Automation.attach_cell(fixture["session_id"], opts)
        %{handle: handle, snapshot: nil}

      value when value in [:text, :json] ->
        {:ok, attached} = Client.attach(fixture["session_id"], opts)
        attached
    end
  end

  defp tui_state(:tui, snapshot, fixture, request) do
    state =
      State.new(nil, {80, 24},
        session_snapshot: snapshot,
        activity: {:starting, {:turn, Turn.new(0, fixture["prompt"])}}
      )

    {state, []} = State.update(state, {:turn_started, request})
    state
  end

  defp tui_state(_surface, _snapshot, _fixture, _request), do: nil

  defp collect_output!(surface, handle, state, events) do
    case Client.output(handle) do
      {:ok, batch} ->
        batch_events = batch["payload"]["events"]

        state =
          if surface == :tui do
            {:ok, next} = TUI.apply_batch(handle, state, batch)
            next
          else
            {:ok, _receipt} = Client.ack(handle, batch["payload"]["acknowledgement_token"])
            state
          end

        collect_output!(surface, handle, state, events ++ batch_events)

      :empty ->
        {events, state}

      {:gap, gap} ->
        raise "unexpected parity gap: #{inspect(gap["payload"])}"

      {:error, reason} ->
        raise "parity output failed: #{inspect(reason)}"
    end
  end

  defp collect_raw_output!(handle, events) do
    case Client.output(handle) do
      {:ok, batch} ->
        {:ok, _receipt} = Client.ack(handle, batch["payload"]["acknowledgement_token"])
        collect_raw_output!(handle, events ++ batch["payload"]["events"])

      :empty ->
        events

      other ->
        raise "unexpected control output: #{inspect(other)}"
    end
  end

  defp normalize(events) do
    replacements = identity_replacements(events)

    Enum.map(events, fn event ->
      sequence = get_in(event, ["payload", "sequence"])

      event
      |> Map.take(["protocol", "version", "family", "type", "session_id", "payload"])
      |> Map.put("id", "event-#{sequence}")
      |> replace_values(replacements)
      |> normalize_generation_identity()
    end)
  end

  defp normalize_generation_identity(event) do
    update_in(event, ["payload", "identities"], fn identities ->
      Enum.map(identities || [], fn identity ->
        identity = Map.delete(identity, "owner_instance_id")

        if identity["kind"] == "session" do
          Map.put(identity, "generation", 1)
        else
          Map.delete(identity, "generation")
        end
      end)
    end)
  end

  defp identity_replacements(events) do
    events
    |> Enum.flat_map(&(get_in(&1, ["payload", "identities"]) || []))
    |> Enum.reduce(%{}, fn identity, replacements ->
      replacement =
        case identity["kind"] do
          "request" -> "$console-request"
          "run" -> "$console-run"
          "client" -> "$client"
          "attachment" -> "$attachment"
          "input" -> "$input"
          _kind -> identity["id"]
        end

      Map.put(replacements, identity["id"], replacement)
    end)
  end

  defp replace_values(value, replacements) when is_binary(value),
    do: Map.get(replacements, value, value)

  defp replace_values(value, replacements) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, replace_values(item, replacements)} end)
  end

  defp replace_values(value, replacements) when is_list(value),
    do: Enum.map(value, &replace_values(&1, replacements))

  defp replace_values(value, _replacements), do: value

  defp render(:tui, _events, state) do
    state
    |> View.render()
    |> Jido.Console.Terminal.Frame.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp render(:automation, events, _state), do: Enum.map(events, & &1["type"])
  defp render(:text, events, _state), do: Text.transcript(events)

  defp render(:json, events, _state) do
    {:ok, encoded} = JSON.encode_stream(events)
    {:ok, decoded} = Jason.decode(encoded)
    decoded
  end

  defp side_effects(ledger) do
    tool = Enum.find(ledger, &(&1["type"] == "tool_started"))
    terminal = Enum.find(ledger, &(&1["type"] == "run_completed"))

    %{
      "tool" => get_in(tool, ["payload", "operation"]),
      "content" => get_in(terminal, ["payload", "content"]),
      "permission" =>
        ledger
        |> Enum.find(&(&1["type"] == "permission_decided"))
        |> get_in(["payload", "decision"]),
      "terminal" => terminal["type"]
    }
  end

  defp run_automation!(args, resolver, output) do
    {:ok, stdout} = StringIO.open("")
    test_pid = self()

    :ok =
      Jido.Console.run(args,
        execution_profile_resolver: resolver,
        runtime_opts: [
          llm: fn _intent, _journal, _context ->
            send(test_pid, :parity_live_provider_called)
            {:error, :live_provider_forbidden}
          end
        ],
        output_device: stdout,
        run_id: "parity-automation-v1"
      )

    {_input, text} = StringIO.contents(stdout)
    [record] = text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    %{
      record: record,
      artifacts:
        output
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, output))
        |> Enum.sort()
    }
  end

  defp profile_resolver(path, digest) do
    fn profile_id, _opts ->
      metadata = %{
        "jido_console.replay" => %{
          "mode" => "replay",
          "fixture_path" => path,
          "fixture_digest" => digest,
          "compatibility" => %{}
        }
      }

      {:ok, registration(profile_id, metadata)}
    end
  end

  defp registration(profile_id, metadata) do
    profile =
      Jidoka.ExecutionEnvironment.SecurityProfile.new!(
        profile_id: profile_id,
        revision: 1,
        digest: "sha256:" <> String.duplicate("a", 64),
        adapter_id: "test.parity-replay",
        required_isolation: :container,
        required_network: :disabled,
        required_workspace: :ephemeral
      )

    capabilities =
      Jidoka.ExecutionEnvironment.AdapterCapabilities.new!(
        adapter_id: "test.parity-replay",
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

  defp names(prefix, suffix) do
    [
      name: :"#{prefix}-sup-#{suffix}",
      storage: :"#{prefix}-storage-#{suffix}",
      registry: :"#{prefix}-reg-#{suffix}",
      tasks: :"#{prefix}-tasks-#{suffix}",
      sessions: :"#{prefix}-sessions-#{suffix}",
      lock: :"#{prefix}-lock-#{suffix}",
      maintenance: :"#{prefix}-maintenance-#{suffix}",
      quota: :"#{prefix}-quota-#{suffix}",
      admission: :"#{prefix}-admission-#{suffix}",
      writer: :"#{prefix}-writer-#{suffix}",
      jido_home: Path.join(System.tmp_dir!(), "jido-console-#{System.pid()}-#{prefix}-#{suffix}")
    ]
  end

  defp await_terminal_open! do
    receive do
      {:parity_terminal_opened, owner, ref} -> {owner, ref}
    after
      10_000 -> raise "parity terminal did not open"
    end
  end

  defp await_frame!(parts, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_frame_parts!(parts, deadline, "")
  end

  defp await_frame_parts!(parts, deadline, latest) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:parity_frame, frame} ->
        if Enum.all?(parts, &String.contains?(frame, &1)) do
          frame
        else
          await_frame_parts!(parts, deadline, frame)
        end
    after
      remaining -> raise "parity frame missing #{inspect(parts)}; latest: #{inspect(latest)}"
    end
  end

  defp receive_exact!(message, timeout) do
    receive do
      ^message -> :ok
    after
      timeout -> raise "missing parity terminal close"
    end
  end

  defp await_agent_value!(agent) do
    case Agent.get(agent, & &1) do
      nil ->
        Process.sleep(1)
        await_agent_value!(agent)

      value ->
        value
    end
  end
end
