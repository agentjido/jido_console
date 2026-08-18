defmodule Jido.Console.Session.PermissionTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.{Identity, Permission}

  test "responses accept only the matching pending request" do
    session = Identity.new!(:session)

    {:ok, table, request} =
      Permission.request(Permission.new(), %{
        id: "apr_1",
        principal: "user",
        rule: "write",
        control: "ctl_1",
        effect: "file_write",
        session_id: session.id,
        generation: session.generation,
        owner_instance_id: session.owner_instance_id,
        run_id: "run_1",
        request_id: "req_1",
        scope: "workspace"
      })

    assert {:ok, _, :approved} =
             Permission.respond(table, %{
               id: request.id,
               session_id: session.id,
               generation: session.generation,
               owner_instance_id: session.owner_instance_id,
               principal: "user",
               decision: :approved
             })

    assert {:error, :stale_result} =
             Permission.respond(table, %{
               id: "apr_missing",
               session_id: session.id,
               generation: session.generation,
               owner_instance_id: session.owner_instance_id,
               principal: "user",
               decision: :denied
             })
  end

  test "rejects incomplete and crossed responses and expires by event" do
    attrs = %{
      id: "approval",
      principal: "user",
      rule: "write",
      control: "control",
      effect: "effect",
      session_id: "session",
      generation: 1,
      owner_instance_id: "owner-1",
      run_id: "run",
      request_id: "request",
      scope: "workspace"
    }

    assert {:error, :incomplete_permission_request} =
             Permission.request(Permission.new(), %{attrs | scope: ""})

    assert {:ok, table, _request} = Permission.request(Permission.new(), attrs)

    assert {:error, :cross_session_result} =
             Permission.respond(table, %{
               id: "approval",
               session_id: "other",
               generation: 1,
               owner_instance_id: "owner-1",
               principal: "user",
               decision: :approved
             })

    assert {:error, :stale_generation} =
             Permission.respond(table, %{
               id: "approval",
               session_id: "session",
               generation: 0,
               owner_instance_id: "old-owner",
               principal: "user",
               decision: :approved
             })

    assert {:error, :cross_principal_result} =
             Permission.respond(table, %{
               id: "approval",
               session_id: "session",
               generation: 1,
               owner_instance_id: "owner-1",
               principal: "other",
               decision: :approved
             })

    assert {:error, :invalid_permission_decision} =
             Permission.respond(table, %{
               id: "approval",
               session_id: "session",
               generation: 1,
               owner_instance_id: "owner-1",
               principal: "user",
               decision: :other
             })

    assert {:ok, empty} = Permission.expire(table, "approval")
    assert empty.pending == %{}
    assert {:error, :stale_result} = Permission.expire(empty, "approval")
  end

  test "expiry uses an injected wall clock" do
    attrs = %{
      id: "approval-clock",
      principal: "user",
      rule: "write",
      control: "control",
      effect: "effect",
      session_id: "session",
      generation: 1,
      owner_instance_id: "owner-1",
      run_id: "run",
      request_id: "request",
      scope: "workspace",
      expires_at_ms: 500
    }

    assert {:ok, table, _request} = Permission.request(Permission.new(), attrs)
    assert {:error, :permission_not_expired} = Permission.expire_due(table, attrs.id, fn -> 499 end)
    assert {:ok, expired} = Permission.expire_due(table, attrs.id, fn -> 500 end)
    assert expired.pending == %{}
    assert {:error, :invalid_durable_clock} = Permission.expire_due(table, attrs.id, fn -> -1 end)
    assert {:error, :stale_result} = Permission.expire_due(table, "missing", fn -> 500 end)

    assert {:ok, no_expiry, _request} = Permission.request(Permission.new(), Map.delete(attrs, :expires_at_ms))
    assert {:error, :expiry_not_configured} = Permission.expire_due(no_expiry, attrs.id, fn -> 500 end)
  end
end
