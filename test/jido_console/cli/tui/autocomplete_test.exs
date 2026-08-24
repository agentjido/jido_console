defmodule Jido.Console.Tui.AutocompleteTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Tui.{Autocomplete, Selection}

  @entries [
    %{identity: "zeta:last", provider: "zeta", model: "last", tier: :unsupported},
    %{identity: "ollama:llama3.2", provider: "ollama", model: "llama3.2", tier: :beta},
    %{
      identity: "openai:gpt-4.1-mini",
      provider: "openai",
      model: "gpt-4.1-mini",
      tier: :supported
    },
    %{identity: "anthropic:claude", provider: "anthropic", model: "claude", tier: :supported},
    %{identity: "ollama:llama3.2", provider: "ollama", model: "llama3.2", tier: :beta},
    %{identity: "stale", provider: "stale", model: "model", tier: :supported},
    %{identity: "bad:tier", provider: "bad", model: "tier", tier: :unknown}
  ]

  setup do
    %{selection: Selection.init(catalog_entries: @entries, model: "ollama:llama3.2")}
  end

  test "derives lower-case command prefixes in registry order", %{selection: selection} do
    result = derive("/", selection)

    assert result.context == :command

    assert Enum.map(result.candidates, & &1.name) == [
             "help",
             "agent",
             "execution-policy",
             "model",
             "profile",
             "new-session",
             "cancel"
           ]

    assert Enum.all?(result.candidates, &(&1.kind == :command and &1.selectable?))
    assert Enum.all?(result.candidates, &is_binary(&1.usage))
    assert Enum.all?(result.candidates, &is_binary(&1.summary))
    assert result.focused_identity == "help"
    assert result.selected_index == 0
    assert result.completion == "/help"

    assert derive("/m", selection).completion == "/model "
    assert derive("/mo", selection).completion == "/model "
    assert derive("/model", selection).completion == "/model "
    assert derive("\t /m", selection).completion == "\t /model "
  end

  test "rejects ineligible command input", %{selection: selection} do
    for input <- ["/MODEL", "//", "//model", "/profile value", "/model x y", "/model\nx"] do
      assert derive(input, selection).context == :inactive, input
    end

    assert Autocomplete.derive("/model", 3, selection).context == :inactive
    assert Autocomplete.derive(<<255>>, 1, selection).context == :inactive
  end

  test "returns non-selectable feedback for an unknown command prefix", %{selection: selection} do
    result = derive("/provider", selection)

    assert result.context == :no_match
    assert [%{kind: :feedback, selectable?: false, reason: :no_match}] = result.candidates
    assert result.completion == nil
  end

  test "derives canonical selectable model candidates", %{selection: selection} do
    result = derive("/model ", selection)

    assert result.context == :model

    assert Enum.map(result.candidates, & &1.identity) == [
             "anthropic:claude",
             "ollama:llama3.2",
             "openai:gpt-4.1-mini"
           ]

    assert Enum.map(result.candidates, & &1.tier) == [:supported, :beta, :supported]
    assert Enum.find(result.candidates, & &1.current?).identity == "ollama:llama3.2"
    assert result.completion == "/model anthropic:claude"
  end

  test "matches model fields by case-insensitive prefix without fuzzy matching", %{
    selection: selection
  } do
    assert identities(derive("/model OLL", selection)) == ["ollama:llama3.2"]
    assert identities(derive("/model LLAMA", selection)) == ["ollama:llama3.2"]
    assert identities(derive("/model OPENAI:G", selection)) == ["openai:gpt-4.1-mini"]

    assert derive("/model lama", selection).context == :no_match
    assert derive("/model lama", selection).completion == nil
  end

  test "preserves focus by identity and resets it when filtering removes the identity", %{
    selection: selection
  } do
    result = Autocomplete.derive("/model ", 7, selection, "ollama:llama3.2")
    assert result.focused_identity == "ollama:llama3.2"
    assert result.selected_index == 1
    assert result.completion == "/model ollama:llama3.2"

    retained = Autocomplete.derive("/model o", 8, selection, result.focused_identity)
    assert retained.focused_identity == "ollama:llama3.2"

    reset = Autocomplete.derive("/model a", 8, selection, result.focused_identity)
    assert reset.focused_identity == "anthropic:claude"
    assert reset.selected_index == 0
  end

  test "moves and clamps the derived selected index", %{selection: selection} do
    result = derive("/model ", selection)

    assert result |> Autocomplete.move(:up) |> Map.fetch!(:selected_index) == 0
    assert result |> Autocomplete.move(:down) |> Map.fetch!(:selected_index) == 1

    assert result
           |> Autocomplete.move(:down)
           |> Autocomplete.move(:down)
           |> Autocomplete.move(:down)
           |> Map.fetch!(:selected_index) == 2
  end

  test "returns a bounded visible slice which keeps focus in view", %{selection: selection} do
    result = Autocomplete.derive("/model ", 7, selection, "openai:gpt-4.1-mini")

    assert %{rows: rows, offset: 1, selected_index: 1, interactive?: true} =
             Autocomplete.visible_slice(result, 2)

    assert Enum.map(rows, & &1.identity) == ["ollama:llama3.2", "openai:gpt-4.1-mini"]

    assert %{rows: [], selected_index: nil, interactive?: false} =
             Autocomplete.visible_slice(result, 0)
  end

  test "returns non-selectable bounded feedback for no matches and invalid catalogs", %{
    selection: selection
  } do
    no_match = derive("/model missing", selection)
    assert no_match.context == :no_match
    assert [%{kind: :feedback, selectable?: false, reason: :no_match}] = no_match.candidates
    assert no_match.focused_identity == nil
    assert no_match.selected_index == nil
    assert no_match.completion == nil

    assert %{rows: [_feedback], interactive?: false} = Autocomplete.visible_slice(no_match, 1)
    assert %{rows: [], interactive?: false} = Autocomplete.visible_slice(no_match, 0)

    for entries <- [[], :invalid, [42], [%{identity: "bad", tier: :supported}]] do
      selection = Selection.init(catalog_entries: entries)
      result = derive("/model ", selection)
      assert result.context == :no_match
      assert [%{kind: :feedback, selectable?: false, reason: :invalid_catalog}] = result.candidates
      assert result.completion == nil
    end
  end

  defp derive(input, selection), do: Autocomplete.derive(input, String.length(input), selection)
  defp identities(result), do: Enum.map(result.candidates, & &1.identity)
end
