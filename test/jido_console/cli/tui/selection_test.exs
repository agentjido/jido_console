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
    assert {:command, ^selection, models} = Selection.handle("/model", selection)
    assert models =~ "openai:gpt-4.1-mini supported"
    assert models =~ "ollama:llama3.2 beta"
    refute models =~ "sk-"

    assert {:command, ^selection, profiles} = Selection.handle("/profile", selection)
    assert profiles =~ "coding.restricted"
    assert profiles =~ "coding.trusted-workspace"
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

  test "model and profile mutation commands require a new thread" do
    selection = Selection.init(catalog_entries: @entries)
    assert {:command, ^selection, notice} = Selection.handle("/model ollama:llama3.2", selection)
    assert notice =~ "new thread"

    assert {:command, ^selection, warning} = Selection.handle("/profile coding.trusted-workspace", selection)
    assert warning =~ "new thread"
    assert warning =~ "not a sandbox"
  end

  test "rejects unavailable selections and blocks a turn" do
    selection = Selection.init(catalog_entries: @entries, model: "missing:model")
    assert {:command, ^selection, notice} = Selection.handle("/model missing:model", selection)
    assert notice =~ "Unavailable"
    assert {:error, reason} = Selection.admit(selection)
    assert reason =~ "unavailable model"
  end

  test "TUI mutation commands do not change the visible run configuration or start work" do
    state = State.new(:session, {80, 12}, catalog_entries: @entries)
    initial = state.selection
    {state, []} = State.update(state, {:terminal, {:text, "/model ollama:llama3.2"}})
    {state, []} = State.update(state, {:terminal, {:key, :enter}})
    assert state.selection == initial
    assert state.activity == :idle
    assert List.last(state.messages).content =~ "new thread"
    assert Frame.row_text(View.render(state), 1) =~ "openai:gpt-4.1-mini"

    {state, []} = State.update(state, {:terminal, {:text, "/profile coding.trusted-workspace"}})
    {state, []} = State.update(state, {:terminal, {:key, :enter}})
    assert state.selection == initial
    assert state.activity == :idle
    assert List.last(state.messages).content =~ "new thread"
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
