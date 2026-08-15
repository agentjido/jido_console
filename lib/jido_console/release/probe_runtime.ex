defmodule Jido.Console.Release.ProbeRuntime do
  @moduledoc false
  @behaviour Jido.Console.Runtime

  alias Jido.Console.Runtime.Jidoka.Result
  alias Jidoka.Cancellation
  alias Jidoka.Event

  defmodule Session do
    @moduledoc false
    @enforce_keys [:mode, :state, :workspace, :expected, :log, :verifier]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            mode: :success | :workflow,
            state: pid(),
            workspace: String.t() | nil,
            expected: String.t() | nil,
            log: String.t() | nil,
            verifier: :mix_test | :private_runtime
          }
  end

  defmodule Request do
    @moduledoc false
    @enforce_keys [:request_id, :turn, :prompt, :owner, :session]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            request_id: String.t(),
            turn: pos_integer(),
            prompt: String.t(),
            owner: pid(),
            session: Jido.Console.Release.ProbeRuntime.Session.t()
          }
  end

  @impl true
  def start_session(_agent, opts) do
    mode = Keyword.get(opts, :probe_mode, :success)

    with {:ok, paths} <- validate_paths(mode, opts),
         {:ok, state} <- Agent.start_link(fn -> %{records: [], turn: 0} end) do
      {:ok,
       %Session{
         mode: mode,
         state: state,
         workspace: paths.workspace,
         expected: paths.expected,
         log: paths.log,
         verifier: paths.verifier
       }}
    end
  end

  @impl true
  def start_turn(%Session{} = session, prompt, owner, _opts) do
    turn = Agent.get_and_update(session.state, fn state -> {state.turn + 1, %{state | turn: state.turn + 1}} end)

    request = %Request{
      request_id: "release-probe-#{turn}",
      turn: turn,
      prompt: prompt,
      owner: owner,
      session: session
    }

    record(session, %{"event" => "turn_started", "request_id" => request.request_id, "prompt" => prompt})
    emit_start_events(request)
    {:ok, request}
  end

  @impl true
  def await(%Request{session: %Session{mode: :success}} = request, _opts) do
    {:ok, request.session, "Release probe completed."}
  end

  def await(%Request{turn: 1} = request, _opts) do
    case inspect_workspace(request.session) do
      {:ok, operations} ->
        Enum.each(operations, &record_operation(request.session, &1))

        result(request, :ok, content: "Inspected café λ source and tests.")

      {:error, reason} ->
        result(request, :error, error: reason)
    end
  end

  def await(%Request{turn: 2} = request, _opts) do
    result(request, :pending_review,
      pending_reviews: [
        %{
          interrupt_id: "release-probe-review-1",
          operation: "coding.edit",
          arguments: %{"path" => "lib/rate_limiter.ex"},
          reason: :mutation,
          expires_at_ms: 60_000
        }
      ]
    )
  end

  def await(%Request{turn: 3} = request, _opts) do
    case verify_workspace(request) do
      {:ok, output} ->
        record_operation(request.session, %{
          "id" => "verify_tests",
          "kind" => "verify",
          "command" => "mix test",
          "status" => "passed"
        })

        record(request.session, %{
          "command" => "mix test",
          "event" => "verification",
          "runner" => verification_runner(request.session.verifier),
          "status" => "passed"
        })

        emit_verification_finished(request)

        result(request, :ok,
          content: "Verification passed. Repository review is ready.",
          coding_reviews: [git_review(request.session)],
          raw: output
        )

      {:error, reason} ->
        emit(request, :effect_failed, 2,
          effect_id: "verify-tests",
          effect_kind: :operation,
          operation: "coding.verify",
          error: reason
        )

        result(request, :error, error: reason)
    end
  end

  def await(%Request{turn: 4}, _opts) do
    receive do
      :release_probe_never -> {:error, :unexpected_release_probe_message}
    end
  end

  def await(%Request{} = request, _opts) do
    result(request, :ok, content: "Release probe completed.")
  end

  @impl true
  def approve(%Result{handle: %Request{turn: 2} = request} = pending, review, opts) do
    with :ok <- require_review(review),
         {:ok, edit_review} <- apply_expected_edit(request.session) do
      record_operation(request.session, %{
        "id" => "edit_implementation",
        "kind" => "edit",
        "path" => "lib/rate_limiter.ex"
      })

      record(request.session, %{"event" => "review", "decision" => "approved"})
      emit_edit_finished(request, Keyword.fetch!(opts, :stream_to))

      %Result{
        pending
        | status: :ok,
          content: "Implemented café λ rate limiter.",
          approval: :approved,
          pending_reviews: [],
          coding_reviews: [edit_review]
      }
    else
      {:error, reason} -> %Result{pending | status: :error, error: reason, approval: :approved}
    end
  end

  def approve(%Result{} = pending, _review, _opts) do
    %Result{pending | status: :error, error: :unexpected_release_probe_approval, approval: :approved}
  end

  @impl true
  def deny(%Result{} = pending, _review, _opts) do
    record(pending.session, %{"event" => "review", "decision" => "denied"})
    %Result{pending | status: :error, error: :review_denied, approval: :denied}
  end

  @impl true
  def cancel(%Request{} = request, _opts) do
    record(request.session, %{"event" => "turn_cancelled", "request_id" => request.request_id})
    {:ok, Cancellation.new!(request_id: request.request_id, cancelled_at_ms: 0)}
  end

  @impl true
  def close_session(%Session{} = session) do
    record(session, %{"event" => "session_closed"})
    records = Agent.get(session.state, &Enum.reverse(&1.records))
    write_log(session, records)
    Agent.stop(session.state)
    :ok
  end

  def close_session(_session), do: :ok

  defp validate_paths(:success, opts) do
    {:ok,
     %{
       workspace: nil,
       expected: nil,
       log: optional_path(Keyword.get(opts, :probe_log)),
       verifier: :mix_test
     }}
  end

  defp validate_paths(:workflow, opts) do
    workspace = absolute_path(Keyword.get(opts, :probe_workspace))
    expected = absolute_path(Keyword.get(opts, :probe_expected))
    log = absolute_path(Keyword.get(opts, :probe_log))
    verifier = Keyword.get(opts, :probe_verifier, :mix_test)

    cond do
      is_nil(workspace) or not File.dir?(workspace) -> {:error, :release_probe_workspace_missing}
      is_nil(expected) or not File.regular?(expected) -> {:error, :release_probe_expected_file_missing}
      is_nil(log) or not File.dir?(Path.dirname(log)) -> {:error, :release_probe_log_directory_missing}
      verifier not in [:mix_test, :private_runtime] -> {:error, :release_probe_verifier_invalid}
      true -> {:ok, %{workspace: workspace, expected: expected, log: log, verifier: verifier}}
    end
  end

  defp validate_paths(mode, _opts), do: {:error, {:invalid_release_probe_mode, mode}}

  defp optional_path(nil), do: nil
  defp optional_path(path), do: absolute_path(path)

  defp absolute_path(path) when is_binary(path) and path != "" do
    if Path.type(path) == :absolute, do: Path.expand(path), else: nil
  end

  defp absolute_path(_path), do: nil

  defp emit_start_events(%Request{session: %Session{mode: :success}} = request) do
    delta =
      Event.build(:llm_delta, [],
        request_id: request.request_id,
        seq: 0,
        data: %{chunk_type: :content, delta: "Release probe completed."}
      )

    send(request.owner, {:jidoka_turn_event, delta})

    send(
      request.owner,
      {:jidoka_turn_event, Event.build(:turn_finished, [delta], request_id: request.request_id, seq: 1)}
    )
  end

  defp emit_start_events(%Request{turn: 1} = request) do
    events = [
      {:effect_planned, 0, "read-implementation", "coding.read"},
      {:effect_planned, 1, "read-tests", "coding.read"},
      {:capability_call_started, 2, "read-implementation", "coding.read"},
      {:capability_call_started, 3, "read-tests", "coding.read"},
      {:capability_call_completed, 4, "read-implementation", "coding.read"},
      {:capability_call_completed, 5, "read-tests", "coding.read"}
    ]

    Enum.each(events, fn {event, seq, effect_id, operation} ->
      emit(request, event, seq,
        effect_id: effect_id,
        effect_kind: :operation,
        operation: operation
      )
    end)

    emit(request, :turn_finished, 6)
  end

  defp emit_start_events(%Request{turn: 2} = request) do
    emit(request, :effect_planned, 0,
      effect_id: "edit-implementation",
      effect_kind: :operation,
      operation: "coding.edit"
    )

    emit(request, :capability_call_started, 1,
      effect_id: "edit-implementation",
      effect_kind: :operation,
      operation: "coding.edit"
    )

    emit(request, :effect_failed, 2,
      effect_id: "edit-implementation",
      effect_kind: :operation,
      operation: "coding.edit",
      error: :stale_fixture_revision
    )

    emit(request, :effect_replayed, 3,
      effect_id: "edit-implementation",
      effect_kind: :operation,
      operation: "coding.edit"
    )
  end

  defp emit_start_events(%Request{turn: 3} = request) do
    emit(request, :effect_planned, 0,
      effect_id: "verify-tests",
      effect_kind: :operation,
      operation: "coding.verify"
    )

    emit(request, :capability_call_started, 1,
      effect_id: "verify-tests",
      effect_kind: :operation,
      operation: "coding.verify"
    )
  end

  defp emit_start_events(%Request{turn: 4} = request) do
    event =
      Event.build(:llm_delta, [],
        request_id: request.request_id,
        seq: 0,
        data: %{chunk_type: :content, delta: "Cancellation fixture running…"}
      )

    send(request.owner, {:jidoka_turn_event, event})
  end

  defp emit_start_events(request), do: emit(request, :turn_finished, 0)

  defp emit_verification_finished(request) do
    emit(request, :capability_call_completed, 2,
      effect_id: "verify-tests",
      effect_kind: :operation,
      operation: "coding.verify"
    )

    emit(request, :effect_planned, 3,
      effect_id: "git-diff",
      effect_kind: :operation,
      operation: "coding.git_diff"
    )

    emit(request, :capability_call_started, 4,
      effect_id: "git-diff",
      effect_kind: :operation,
      operation: "coding.git_diff"
    )

    emit(request, :capability_call_completed, 5,
      effect_id: "git-diff",
      effect_kind: :operation,
      operation: "coding.git_diff"
    )

    emit(request, :turn_finished, 6)
  end

  defp emit_edit_finished(%Request{} = request, stream_to) do
    request = %Request{request | owner: stream_to}

    emit(request, :capability_call_completed, 4,
      effect_id: "edit-implementation",
      effect_kind: :operation,
      operation: "coding.edit"
    )

    emit(request, :turn_finished, 5)
  end

  defp emit(request, event, seq, attrs \\ []) do
    event = Event.build(event, [], Keyword.merge([request_id: request.request_id, seq: seq], attrs))
    send(request.owner, {:jidoka_turn_event, event})
  end

  defp inspect_workspace(%Session{} = session) do
    operations = [
      %{"id" => "inspect_implementation", "kind" => "read", "path" => "lib/rate_limiter.ex"},
      %{"id" => "inspect_tests", "kind" => "read", "path" => "test/rate_limiter_test.exs"}
    ]

    case Enum.find(operations, fn operation ->
           not File.regular?(Path.join(session.workspace, operation["path"]))
         end) do
      nil -> {:ok, operations}
      missing -> {:error, {:release_probe_read_missing, missing["path"]}}
    end
  end

  defp apply_expected_edit(%Session{} = session) do
    target = Path.join(session.workspace, "lib/rate_limiter.ex")

    with {:ok, before} <- File.read(target),
         {:ok, after_content} <- File.read(session.expected),
         :ok <- File.write(target, after_content) do
      {:ok,
       %{
         "kind" => "edit",
         "path" => "lib/rate_limiter.ex",
         "action" => "edit",
         "operation_id" => "edit-implementation",
         "status" => "changed",
         "before_sha256" => sha256(before),
         "after_sha256" => sha256(after_content),
         "checkpoint" => %{"checkpoint_ref" => "release-probe-checkpoint"},
         "diff" => %{
           "before_lines" => line_count(before),
           "after_lines" => line_count(after_content),
           "changed_before_lines" => line_count(before),
           "changed_after_lines" => line_count(after_content)
         }
       }}
    else
      {:error, reason} -> {:error, {:release_probe_edit_failed, reason}}
    end
  end

  defp verify_workspace(%Request{session: %Session{verifier: :mix_test}} = request) do
    case System.cmd("mix", ["test"],
           cd: request.session.workspace,
           env: [{"MIX_ENV", "test"}],
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:release_probe_verification_failed, status, output}}
    end
  rescue
    error ->
      location = __STACKTRACE__ |> List.first() |> Exception.format_stacktrace_entry()
      {:error, {:release_probe_verification_crashed, "#{location}: #{Exception.message(error)}"}}
  end

  defp verify_workspace(%Request{session: %Session{verifier: :private_runtime}} = request) do
    source = Path.join(request.session.workspace, "lib/rate_limiter.ex")

    case Application.ensure_all_started(:elixir) do
      {:ok, _applications} -> compile_and_check(source)
      {:error, reason} -> {:error, {:release_probe_verification_failed, {:elixir_start_failed, reason}}}
    end
  rescue
    error ->
      location = __STACKTRACE__ |> List.first() |> Exception.format_stacktrace_entry()
      {:error, {:release_probe_verification_crashed, "#{location}: #{Exception.message(error)}"}}
  catch
    kind, reason -> {:error, {:release_probe_verification_crashed, {kind, reason}}}
  end

  defp compile_and_check(source) do
    compiled = Code.compile_file(source)

    try do
      with {module, _bytecode} when is_atom(module) <- List.keyfind(compiled, RateLimiter, 0),
           :ok <- check_rate_limiter_behaviour(module) do
        {:ok, "private runtime behavior checks passed"}
      else
        nil -> {:error, {:release_probe_verification_failed, :rate_limiter_module_missing}}
        {:error, reason} -> {:error, {:release_probe_verification_failed, reason}}
      end
    after
      Enum.each(compiled, fn {module, _bytecode} ->
        :code.purge(module)
        :code.delete(module)
      end)
    end
  end

  defp check_rate_limiter_behaviour(module) do
    limiter = module.new(2, 1_000)

    with {:ok, limiter} <- module.allow(limiter, :api, 100),
         {:ok, limiter} <- module.allow(limiter, :api, 900),
         {:error, :rate_limited, ^limiter} <- module.allow(limiter, :api, 999),
         other_key = module.new(1, 1_000),
         {:ok, other_key} <- module.allow(other_key, :api, 999),
         {:ok, other_key} <- module.allow(other_key, :admin, 999),
         {:error, :rate_limited, other_key} <- module.allow(other_key, :api, 999),
         {:ok, _reset} <- module.allow(other_key, :api, 1_000) do
      :ok
    else
      result -> {:error, {:unexpected_rate_limiter_result, result}}
    end
  end

  defp verification_runner(:mix_test), do: "system_mix"
  defp verification_runner(:private_runtime), do: "private_runtime"

  defp git_review(%Session{} = session) do
    {patch, 0} =
      System.cmd("git", ["diff", "--", "lib/rate_limiter.ex"],
        cd: session.workspace,
        stderr_to_stdout: true
      )

    %{
      "kind" => "git_diff",
      "status" => "changed",
      "files" => [
        %{
          "path" => "lib/rate_limiter.ex",
          "binary" => false,
          "additions" => count_patch_lines(patch, "+"),
          "deletions" => count_patch_lines(patch, "-")
        }
      ],
      "patch" => patch,
      "truncated" => false
    }
  end

  defp require_review(%{interrupt_id: "release-probe-review-1"}), do: :ok
  defp require_review(_review), do: {:error, :unexpected_release_probe_review}

  defp result(%Request{} = request, status, attrs) do
    struct!(
      Result,
      Keyword.merge(
        [
          request_id: request.request_id,
          status: status,
          session: request.session,
          runtime_opts: [],
          extension_host: nil,
          local_resources: nil,
          handle: request
        ],
        attrs
      )
    )
  end

  defp record_operation(session, operation) do
    record(session, %{"event" => "operation", "operation" => operation})
  end

  defp record(%Session{} = session, entry) do
    Agent.update(session.state, &Map.update!(&1, :records, fn records -> [entry | records] end))
  end

  defp write_log(%Session{log: nil}, _records), do: :ok

  defp write_log(%Session{mode: :success, log: log}, records) do
    contents =
      records
      |> Enum.filter(&(&1["event"] == "turn_started"))
      |> Enum.map_join("", fn record -> "turn #{digest(record["prompt"])}\n" end)

    File.write(log, contents)
  end

  defp write_log(%Session{mode: :workflow, log: log}, records) do
    contents = Enum.map_join(records, "", &(Jason.encode!(&1) <> "\n"))
    File.write(log, contents)
  end

  defp digest(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp sha256(value), do: "sha256:" <> digest(value)

  defp line_count(""), do: 0
  defp line_count(value), do: value |> String.split("\n", trim: true) |> length()

  defp count_patch_lines(patch, marker) do
    patch
    |> String.split("\n")
    |> Enum.count(&(String.starts_with?(&1, marker) and not String.starts_with?(&1, marker <> marker <> marker)))
  end
end
