defmodule Jido.Console.Tui.SelectionTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.{Selection, State, View}
  alias TermUI.Frame

  @entries [
    %{identity: "openai:gpt-4.1-mini", provider: "openai", model: "gpt-4.1-mini", tier: :supported},
    %{identity: "ollama:llama3.2", provider: "ollama", model: "llama3.2", tier: :beta}
  ]

  test "lists catalog models and allowed profiles" do
    selection = Selection.init(catalog_entries: @entries)
    assert {:ok, models} = Selection.list_models(selection)
    assert models =~ "openai:gpt-4.1-mini supported"
    assert models =~ "ollama:llama3.2 beta"
    assert models =~ "current"
    refute models =~ "sk-"

    profiles = Selection.list_profiles()
    assert profiles =~ "coding.restricted"
    assert profiles =~ "coding.trusted-workspace"
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

  test "profile mutation commands require a new thread" do
    selection = Selection.init(catalog_entries: @entries)
    assert selection.model == "openai:gpt-4.1-mini"
    warning = Selection.profile_notice("coding.trusted-workspace")
    assert warning =~ "new thread"
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
    state = State.new(:session, {80, 12}, catalog_entries: @entries)
    initial = state.selection
    {state, []} = State.update(state, {:terminal, {:text, "/model ollama:llama3.2"}})
    {state, effects} = State.update(state, {:terminal, {:key, :enter}})
    assert state.selection == initial
    assert state.activity == :idle
    assert effects == []
    assert List.last(state.command_notices) =~ "still starting"
    assert Frame.row_text(View.render(state), 1) =~ "openai:gpt-4.1-mini"

    {state, []} = State.update(state, {:terminal, {:text, "/profile coding.trusted-workspace"}})
    {state, []} = State.update(state, {:terminal, {:key, :enter}})
    assert state.selection == initial
    assert state.activity == :idle
    assert List.last(state.command_notices) =~ "new thread"
    assert Frame.row_text(View.render(state), 1) =~ "coding.restricted"
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
