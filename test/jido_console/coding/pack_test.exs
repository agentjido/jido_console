defmodule Jido.Console.Coding.PackTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Coding.Pack
  alias Jido.Console.ExecutionPolicy
  alias Jidoka.Extension.Request

  test "keeps pack state independent from the restricted execution policy" do
    assert {:ok, pack} = Pack.resolve(coding_pack: :disabled)
    assert Pack.projection(pack) == %{"id" => nil, "status" => "disabled"}

    assert {:ok, policy} = ExecutionPolicy.resolve(application_proposal: ExecutionPolicy.restricted_id())
    assert policy.execution_policy_id == ExecutionPolicy.restricted_id()
  end

  test "removes a reserved document request when disabled and replaces it when enabled" do
    forged = Request.new!(id: Jidoka.CodingPack.id(), config: %{"enabled_by_document" => true})
    other = Request.new!(id: "acme.safe")
    base = Jido.Console.Agents.Default.spec()
    spec = Jidoka.Agent.Spec.new!(%{base | extensions: [forged, other]})

    assert {:ok, disabled} = Pack.resolve(coding_pack: :disabled)
    assert {:ok, disabled_spec} = Pack.apply(disabled, spec)
    refute Enum.any?(disabled_spec.extensions, &(&1.id == Jidoka.CodingPack.id()))
    assert Enum.any?(disabled_spec.extensions, &(&1.id == "acme.safe"))

    assert {:ok, enabled} = Pack.resolve(coding_pack: Jidoka.CodingPack.id())
    assert {:ok, enabled_spec} = Pack.apply(enabled, spec)
    assert %Request{config: %{}, enabled: true} = Enum.find(enabled_spec.extensions, &(&1.id == Jidoka.CodingPack.id()))
    assert Enum.count(enabled_spec.extensions, &(&1.id == Jidoka.CodingPack.id())) == 1
  end

  test "rejects module-shaped and malformed pack choices" do
    assert {:error, :coding_module_name_forbidden} = Pack.resolve(coding_pack: "Elixir.Untrusted")
    assert {:error, {:invalid_coding_pack, 42}} = Pack.resolve(coding_pack: 42)
  end
end
