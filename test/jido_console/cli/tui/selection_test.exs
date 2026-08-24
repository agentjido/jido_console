defmodule Jido.Console.Tui.SelectionTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.{Selection, State, View}
  alias TermUI.Frame

  @entries [
    %{identity: "openai:gpt-4.1-mini", provider: "openai", model: "gpt-4.1-mini", tier: :supported},
    %{identity: "ollama:llama3.2", provider: "ollama", model: "llama3.2", tier: :beta}
  ]

  test "lists catalog models and allowed execution policies" do
    selection = Selection.init(catalog_entries: @entries)
    assert {:ok, models} = Selection.list_models(selection)
    assert models =~ "openai:gpt-4.1-mini supported"
    assert models =~ "ollama:llama3.2 beta"
    assert models =~ "current"
    refute models =~ "sk-"

    policies = Selection.list_execution_policies(selection)
    assert policies =~ "coding.restricted current"
    assert policies =~ "coding.trusted-workspace"
  end

  test "lists only selectable tiers in stable identity order" do
    entries = [
      %{identity: "z:last", provider: "z", model: "last", tier: :unsupported},
      %{identity: "b:beta", provider: "b", model: "beta", tier: :beta},
      %{identity: "a:available", provider: "a", model: "available", tier: :available},
      %{identity: "a:supported", provider: "a", model: "supported", tier: :supported}
    ]

    selection = Selection.init(catalog_entries: entries, model: "b:beta")
    assert {:ok, models} = Selection.list_models(selection)

    assert String.split(models, "\n") == [
             "Models:",
             "a:supported supported",
             "b:beta beta current"
           ]
  end

  test "projects de-duplicated selectable model data with the current marker" do
    entries = [
      %{identity: "z:unsupported", provider: "z", model: "unsupported", tier: :unsupported},
      %{identity: "b:beta", provider: "b", model: "beta", tier: :beta},
      %{identity: "a:available", provider: "a", model: "available", tier: :available},
      %{identity: "a:supported", provider: "a", model: "supported", tier: :supported},
      %{identity: "b:beta", provider: "b", model: "beta", tier: :beta},
      %{identity: "stale", provider: "x", model: "stale", tier: :supported},
      %{identity: 42, provider: "x", model: "bad", tier: :supported}
    ]

    selection = Selection.init(catalog_entries: entries, model: "b:beta")

    assert {:ok, models} = Selection.selectable_models(selection)

    assert models == [
             %{
               identity: "a:supported",
               provider: "a",
               model: "supported",
               tier: :supported,
               current?: false
             },
             %{
               identity: "b:beta",
               provider: "b",
               model: "beta",
               tier: :beta,
               current?: true
             }
           ]
  end

  test "model projection rejects catalogs with no selectable valid entries" do
    for entries <- [
          [],
          :invalid,
          [42],
          [%{identity: <<255>>, provider: <<255>>, model: "bad", tier: :supported}],
          [%{identity: "bad", tier: :supported}],
          [%{identity: "a:available", provider: "a", model: "available", tier: :available}]
        ] do
      selection = Selection.init(catalog_entries: entries)

      assert {:error, %Jido.Console.Error.ConfigurationError{}} =
               Selection.selectable_models(selection)
    end
  end

  test "selects exact supported and beta identities only" do
    entries = [
      %{identity: "a:supported", provider: "a", model: "supported", tier: :supported},
      %{identity: "b:beta", provider: "b", model: "beta", tier: :beta},
      %{identity: "c:available", provider: "c", model: "available", tier: :available},
      %{identity: "d:unsupported", provider: "d", model: "unsupported", tier: :unsupported}
    ]

    selection = Selection.init(catalog_entries: entries)
    assert {:ok, beta} = Selection.resolve_model("b:beta", selection)
    assert beta.tier == :beta

    for identity <- ["missing:model", "c:available", "d:unsupported", "supported"] do
      assert {:error, error} = Selection.resolve_model(identity, selection)
      assert Exception.message(error) =~ identity
    end
  end

  test "returns a configuration error for an empty or invalid catalog" do
    for entries <- [[], [%{identity: "bad", tier: :supported}]] do
      selection = Selection.init(catalog_entries: entries)
      assert {:error, %Jido.Console.Error.ConfigurationError{}} = Selection.list_models(selection)
    end
  end

  test "builds the startup selection without resolving model metadata" do
    selection =
      Selection.init(
        model_policy: [
          %{identity: "openai:gpt-4.1-mini", tier: :supported},
          %{identity: "ollama:llama3.2", tier: :beta}
        ],
        model_resolver: fn _identity -> raise "startup must not load model metadata" end
      )

    assert selection.model == "openai:gpt-4.1-mini"
    assert selection.model_tier == :supported

    assert Enum.map(selection.catalog_entries, & &1.identity) == [
             "openai:gpt-4.1-mini",
             "ollama:llama3.2"
           ]
  end

  test "keeps the profile command as a warning alias" do
    selection = Selection.init(catalog_entries: @entries)
    assert selection.model == "openai:gpt-4.1-mini"
    warning = Selection.profile_notice("coding.trusted-workspace")
    assert warning =~ "Deprecated"
    assert warning =~ "/execution-policy"
    assert warning =~ "not a sandbox"
  end

  test "rejects unavailable selections and blocks a turn" do
    selection = Selection.init(catalog_entries: @entries, model: "missing:model")
    assert {:error, error} = Selection.resolve_model("missing:model", selection)
    assert Exception.message(error) =~ "Unavailable"
    assert {:error, reason} = Selection.admit(selection)
    assert reason =~ "unavailable model"
  end

  test "TUI mutation commands dispatch owner selection without starting work" do
    state = State.new(:session, {80, 12}, catalog_entries: @entries, session_client: :client)
    initial = state.selection
    {state, []} = State.update(state, {:terminal, {:text, "/model ollama:llama3.2"}})
    {state, effects} = State.update(state, {:terminal, {:key, :enter}})
    assert state.selection == initial
    assert state.activity == :idle
    assert effects == [{:select_model, "ollama:llama3.2"}]
    assert Frame.row_text(View.render(state), 1) =~ "openai:gpt-4.1-mini"

    {state, []} = State.update(state, {:terminal, {:text, "/agent agents/review agent.yaml"}})

    {state, [{:select_agent, "agents/review agent.yaml"}]} =
      State.update(state, {:terminal, {:key, :enter}})

    {state, []} = State.update(state, {:terminal, {:text, "/execution-policy coding.trusted-workspace"}})

    {state, [{:select_execution_policy, "coding.trusted-workspace", nil}]} =
      State.update(state, {:terminal, {:key, :enter}})

    assert state.selection == initial
    assert state.activity == :idle
    assert List.last(state.command_notices) =~ "not a sandbox"

    {state, []} = State.update(state, {:terminal, {:text, "/profile coding.restricted"}})

    {state, [{:select_execution_policy, "coding.restricted", nil}]} =
      State.update(state, {:terminal, {:key, :enter}})

    assert List.last(state.command_notices) =~ "deprecated"
    assert Frame.row_text(View.render(state), 1) =~ "coding.restricted"
  end

  test "restores pending policy state and requires the exact owner request" do
    selection =
      Selection.init(catalog_entries: @entries)
      |> Selection.restore_binding(
        %{
          "agent" => %{"id" => "trusted-agent", "source" => %{"kind" => "file"}},
          "execution_policy" => %{"id" => nil, "requested_id" => "coding.trusted-workspace"}
        },
        :needs_policy
      )

    assert {:error, reason} = Selection.admit(selection)
    assert reason =~ "/execution-policy"
    assert reason =~ "coding.trusted-workspace"
    assert Selection.list_execution_policies(selection) =~ "coding.trusted-workspace requested"
  end

  test "shows current owner values and locks selection commands" do
    binding = %{
      "agent" => %{
        "id" => "reviewer",
        "source" => %{"kind" => "file", "label" => "review.yaml", "digest" => "sha256:agent"}
      },
      "execution_policy" => %{"id" => "coding.restricted", "requested_id" => nil}
    }

    state = State.new(:session, {80, 14}, catalog_entries: @entries, session_client: :client)
    selection = Selection.restore_binding(state.selection, binding, :locked)
    state = %{state | selection: selection}

    {state, []} = State.update(state, {:terminal, {:text, "/agent"}})
    {state, []} = State.update(state, {:terminal, {:key, :enter}})
    assert List.last(state.command_notices) =~ "review.yaml"
    refute List.last(state.command_notices) =~ "/private/"

    {state, []} = State.update(state, {:terminal, {:text, "/agent other.yaml"}})
    {state, []} = State.update(state, {:terminal, {:key, :enter}})
    assert List.last(state.command_notices) =~ "locked"

    {state, []} = State.update(state, {:terminal, {:text, "/execution-policy coding.trusted-workspace"}})
    {state, []} = State.update(state, {:terminal, {:key, :enter}})
    assert List.last(state.command_notices) =~ "locked"
  end

  test "an unavailable model prevents the turn from starting" do
    state = State.new(:session, {80, 12}, catalog_entries: @entries, model: "missing:model")
    {state, []} = State.update(state, {:terminal, {:text, "do work"}})
    {state, effects} = State.update(state, {:terminal, {:key, :enter}})
    assert effects == []
    assert {:failed, :selection, _reason, error} = state.activity
    assert error =~ "unavailable model"
  end
end
