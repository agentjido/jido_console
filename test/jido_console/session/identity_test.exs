defmodule Jido.Console.Session.IdentityTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Identity
  alias Jido.Console.Session.Identity.{Admission, Invocation}

  test "each identity kind has a stable format and owner" do
    {:ok, session} = Identity.new(:session)

    Enum.each(Map.keys(Identity.kinds()), fn kind ->
      {:ok, identity} = Identity.new(kind, session_id: session.id)
      assert identity.owner == Identity.owner_for(kind)
      assert :ok = Identity.validate_id(identity.id, kind)
      assert identity.session_id == if(kind == :session, do: identity.id, else: session.id)
      assert {:ok, _} = Jason.encode(Identity.to_protocol(identity))
    end)
  end

  test "stale, repeated, and cross-session results cannot resolve current work" do
    live = Identity.new!(:request, session_id: Identity.new!(:session).id, id: "req_live")
    state = Admission.new(live)

    assert {:ok, state} = Admission.admit(state, live)
    assert {:error, :repeated_result} = Admission.admit(state, live)

    stale = %{live | generation: 0}
    assert {:error, :stale_result} = Admission.admit(Admission.new(%{live | generation: 2}), stale)

    other = Identity.new!(:request, session_id: Identity.new!(:session).id, id: "req_other")
    assert {:error, :cross_session_result} = Admission.admit(Admission.new(live), other)

    assert {:error, :authority_source_rejected} =
             Admission.admit(Admission.new(live), Map.put(live, :owner, "origin"))

    refute Identity.authority_source?("session")
  end

  test "invocation identity names the effective call without credentials" do
    session = Identity.new!(:session)

    assert {:ok, invocation} =
             Invocation.new(
               session_id: session.id,
               provider: "openai",
               model: "gpt-4.1",
               variant: "default",
               generation: [temperature: 0],
               profile: "restricted",
               prompt: "hello",
               tool_schema: %{name: "read"},
               skill_schema: %{},
               fallback_attempt: 1
             )

    record = Invocation.to_protocol(invocation)
    assert record["provider"] == "openai"
    assert record["model"] == "gpt-4.1"
    assert record["fallback_attempt"] == 1
    refute Map.has_key?(record, "credential")
    assert {:ok, _} = Jason.encode(record)

    assert {:error, :credential_in_identity} =
             Invocation.new(session_id: session.id, provider: "openai", model: "gpt-4.1", token: "sk")
  end
end
