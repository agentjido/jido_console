defmodule Jido.Console.Tui.EffectsTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Request
  alias Jido.Console.Tui.{Effects, State, Workers}

  defmodule SessionClient do
    def start_turn(handle, prompt, opts) do
      send(handle.test_pid, {:turn_started, prompt, opts})

      {:ok,
       %Request{
         id: "session-request",
         request_id: "runtime-request",
         run_id: "run",
         session_id: "session"
       }}
    end

    def cancel(handle, request, opts) do
      send(handle.test_pid, {:cancel_requested, request, opts})
      {:ok, :requested}
    end

    def respond_review(handle, decision, request, review, opts) do
      send(handle.test_pid, {:review_response, decision, request, review, opts})
      {:ok, :requested}
    end
  end

  test "dispatches turn, cancellation, prompt, and selection work without polling" do
    handle = %{test_pid: self()}
    state = %{State.new(:session, {80, 24}, catalog_entries: []) | session_client: handle}
    client_opts = [session_client_module: SessionClient]

    request = %Request{
      id: "session-request",
      request_id: "runtime-request",
      run_id: "run",
      session_id: "session"
    }

    assert {:continue, workers} =
             Effects.dispatch(state, [{:start_turn, "first"}], :unused, client_opts, %{})

    assert_receive {:turn_started, "first", turn_options}
    assert turn_options[:turn_opts][:context] == %{}
    assert :ignore = complete_single(workers)

    context = %{"source" => "test"}

    assert {:continue, workers} =
             Effects.dispatch(
               state,
               [{:start_turn, "second", context}],
               :unused,
               client_opts,
               %{}
             )

    assert_receive {:turn_started, "second", turn_options}
    assert turn_options[:turn_opts][:context] == context
    assert :ignore = complete_single(workers)

    assert {:continue, workers} =
             Effects.dispatch(
               state,
               [{:cancel_turn, request}],
               :unused,
               client_opts ++ [cancel_opts: [reason: :user]],
               %{}
             )

    assert_receive {:cancel_requested, ^request, [reason: :user]}
    assert :ignore = complete_single(workers)

    for decision <- [:approve, :deny] do
      effect = {:respond_review, decision, request, :paused_result, :review}

      assert {:continue, workers} =
               Effects.dispatch(
                 state,
                 [effect],
                 :unused,
                 client_opts ++ [review_opts: [source: :test]],
                 %{}
               )

      assert_receive {:review_response, ^decision, ^request, :review, [source: :test]}
      assert :ignore = complete_single(workers)
    end

    assert {:continue, workers} =
             Effects.dispatch(
               state,
               [{:prepare_prompt, "hello"}],
               :unused,
               [coding_setup_resolved: :coding, prompt_preparer: :invalid],
               %{}
             )

    assert {:event, {:prompt_error, :invalid_prompt_preparer}} = complete_single(workers)

    selection = %{model: "test"}

    assert {:continue, workers} =
             Effects.dispatch(state, [{:apply_selection, selection}], :unused, [], %{})

    assert {:event, {:prompt_error, :runtime_owner_missing}} = complete_single(workers)

    assert {:continue, workers} =
             Effects.dispatch(
               state,
               [{:apply_selection, selection}],
               :unused,
               [runtime_owner: self()],
               %{}
             )

    assert_receive {:reconfigure, worker_pid, ^selection}
    send(worker_pid, {:jido_runtime_reconfigure, self(), {:ok, %{ready: true}}})
    assert {:reconfigured, %{ready: true}} = complete_single(workers)

    assert {:continue, workers} =
             Effects.dispatch(
               state,
               [{:apply_selection, selection}],
               :unused,
               [runtime_owner: self(), selection_apply_timeout: 0],
               %{}
             )

    assert {:event, {:prompt_error, :selection_apply_timeout}} = complete_single(workers)
    assert {:exit, %{}} = Effects.dispatch(state, [:exit], :unused, [], %{})
  end

  test "normalizes every worker completion result" do
    cases = [
      {{:apply_selection, :selection}, {:ok, {:error, :failed}}, {:event, {:prompt_error, :failed}}},
      {{:apply_selection, :selection}, {:ok, :invalid},
       {:event, {:prompt_error, {:invalid_selection_result, :invalid}}}},
      {{:apply_selection, :selection}, {:crash, :failed}, {:event, {:prompt_error, :failed}}},
      {{:prepare_prompt, "prompt"}, {:ok, {:ok, "ready", %{}}}, {:event, {:prompt_ready, "ready", %{}}}},
      {{:prepare_prompt, "prompt"}, {:ok, {:error, :failed}}, {:event, {:prompt_error, :failed}}},
      {{:prepare_prompt, "prompt"}, {:ok, :invalid}, {:event, {:prompt_error, {:invalid_prompt_result, :invalid}}}},
      {{:prepare_prompt, "prompt"}, {:crash, :failed}, {:event, {:prompt_error, :failed}}},
      {:session_start_turn, {:ok, {:error, :failed}}, {:event, {:turn_result, {:error, :failed}}}},
      {:session_start_turn, {:ok, :invalid},
       {:event, {:turn_result, {:error, {:invalid_start_turn_result, :invalid}}}}},
      {:session_start_turn, {:crash, :failed}, {:event, {:turn_result, {:error, :failed}}}},
      {:session_cancel, {:ok, {:error, :request_already_finished}}, :ignore},
      {:session_cancel, {:ok, {:error, :failed}}, {:event, {:turn_result, {:error, :failed}}}},
      {:session_cancel, {:ok, :invalid}, {:event, {:turn_result, {:error, {:invalid_cancel_result, :invalid}}}}},
      {:session_cancel, {:crash, :failed}, {:event, {:turn_result, {:error, :failed}}}},
      {{:session_review, :approve}, {:ok, {:error, :failed}}, {:event, {:turn_result, {:error, :failed}}}},
      {{:session_review, :approve}, {:ok, :invalid},
       {:event, {:turn_result, {:error, {:invalid_review_result, :invalid}}}}},
      {{:session_review, :approve}, {:crash, :failed}, {:event, {:turn_result, {:error, :failed}}}}
    ]

    Enum.each(cases, fn {kind, outcome, expected} ->
      assert Effects.complete(worker(kind), outcome) == expected
    end)
  end

  defp complete_single(workers) do
    assert [{pid, worker}] = Map.to_list(workers)
    assert_receive {:jido_tui_effect_result, ^pid, outcome}
    assert {:ok, ^worker, %{}} = Workers.pop(workers, pid)
    Effects.complete(worker, outcome)
  end

  defp worker(kind) do
    %Workers.Worker{pid: self(), ref: make_ref(), kind: kind}
  end
end
