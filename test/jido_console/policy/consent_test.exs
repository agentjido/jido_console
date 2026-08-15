defmodule Jido.Console.Policy.ConsentTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Policy.Consent
  alias Jido.Console.Tui.Selection

  @current %{
    provider: "openai",
    model: "gpt-4.1-mini",
    data_boundary: "restricted",
    cost_class: :standard,
    capability: "tools"
  }

  test "does not request consent for a no-change fallback" do
    assert {:ok, :not_required} = Consent.request(@current, @current)
  end

  test "requires consent for each boundary-changing fallback" do
    Enum.each(
      [
        %{provider: "anthropic", model: "claude-sonnet-4-20250514"},
        %{data_boundary: "trusted"},
        %{cost_class: :higher},
        %{capability: "vision"}
      ],
      fn change ->
        proposed = Map.merge(@current, change)
        assert {:ok, request} = Consent.request(@current, proposed)
        assert request.changes != []
        refute inspect(request) =~ "sk-"
        refute Consent.format_request(request) =~ "sk-"
      end
    )
  end

  test "accept applies only the exact proposed change" do
    proposed = Map.put(@current, :provider, "anthropic")
    assert {:ok, request} = Consent.request(@current, proposed)
    assert {:ok, grant} = Consent.decide(request, :accept, request.id)
    assert {:ok, applied} = Consent.apply_grant(@current, grant)
    assert applied.provider == "anthropic"
    assert grant.request.consumed
    assert {:error, :consent_consumed} = Consent.decide(grant.request, :accept, request.id)

    other = %{request | id: "different"}
    assert {:error, :consent_mismatch} = Consent.decide(other, :accept, request.id)
    consumed = %{request | consumed: true}
    assert {:error, :consent_consumed} = Consent.decide(consumed, :accept, request.id)
  end

  test "rejection leaves the selected model and profile unchanged" do
    selection = Selection.init(catalog_entries: [], model: "openai:gpt-4.1-mini")
    proposed = %{provider: "anthropic", model: "claude-sonnet-4-20250514"}
    assert {:ok, request} = Consent.request(@current, proposed)
    assert {:ok, grant} = Consent.decide(request, :reject, request.id)
    assert {:ok, ^selection} = Consent.apply_grant(selection, grant)
  end
end
