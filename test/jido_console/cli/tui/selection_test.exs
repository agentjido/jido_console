defmodule Jido.Console.Tui.SelectionTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.{Selection, State, View}

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

  test "selects a model and trusted profile without applying silently" do
    selection = Selection.init(catalog_entries: @entries)
    assert {:command, next, notice} = Selection.handle("/model openai:gpt-4.1-mini", selection)
    assert next.model == "openai:gpt-4.1-mini"
    assert notice =~ "Selected openai:gpt-4.1-mini"

    assert {:command, trusted, warning} = Selection.handle("/profile coding.trusted-workspace", next)
    assert trusted.profile_id == "coding.trusted-workspace"
    assert warning =~ "not a sandbox"
    assert Selection.label(trusted) =~ "not a sandbox"
  end

  test "rejects unavailable selections and blocks a turn" do
    selection = Selection.init(catalog_entries: @entries, model: "missing:model")
    assert {:command, ^selection, notice} = Selection.handle("/model missing:model", selection)
    assert notice =~ "Unavailable"
    assert {:error, reason} = Selection.admit(selection)
    assert reason =~ "unavailable model"
  end

  test "TUI slash commands change the visible run configuration" do
    state = State.new(:session, {80, 12}, catalog_entries: @entries)
    {state, []} = State.update(state, {:terminal, {:text, "/model ollama:llama3.2"}})
    {state, [{:apply_selection, selection}]} = State.update(state, {:terminal, {:key, :enter}})
    assert selection.model == "ollama:llama3.2"
    assert state.selection.model == "ollama:llama3.2"
    assert state.status == :resolving
    assert List.last(state.messages).content =~ "Selected ollama:llama3.2"
    assert Enum.join(View.render(state).rows, "\n") =~ "ollama:llama3.2"

    {state, []} = State.update(state, {:runtime_ready, :session, []})
    {state, []} = State.update(state, {:terminal, {:text, "/profile coding.trusted-workspace"}})
    {state, [{:apply_selection, trusted}]} = State.update(state, {:terminal, {:key, :enter}})
    assert trusted.profile_id == "coding.trusted-workspace"
    assert state.selection.profile_id == "coding.trusted-workspace"
    assert Enum.join(View.render(state).rows, "\n") =~ "not a sandbox"
  end

  test "an unavailable model prevents the turn from starting" do
    state = State.new(:session, {80, 12}, catalog_entries: @entries, model: "missing:model")
    {state, []} = State.update(state, {:terminal, {:text, "do work"}})
    {state, effects} = State.update(state, {:terminal, {:key, :enter}})
    assert effects == []
    assert state.status == :error
    assert state.error =~ "unavailable model"
  end
end
