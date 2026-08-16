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
        run_id: "run_1",
        request_id: "req_1",
        scope: "workspace"
      })

    assert {:ok, _, :approved} =
             Permission.respond(table, %{id: request.id, session_id: session.id, principal: "user", decision: :approved})

    assert {:error, :stale_result} =
             Permission.respond(table, %{
               id: "apr_missing",
               session_id: session.id,
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
      run_id: "run",
      request_id: "request",
      scope: "workspace"
    }

    assert {:error, :incomplete_permission_request} =
             Permission.request(Permission.new(), %{attrs | scope: ""})

    assert {:ok, table, _request} = Permission.request(Permission.new(), attrs)

    assert {:error, :cross_session_result} =
             Permission.respond(table, %{id: "approval", session_id: "other", principal: "user", decision: :approved})

    assert {:error, :cross_principal_result} =
             Permission.respond(table, %{id: "approval", session_id: "session", principal: "other", decision: :approved})

    assert {:error, :invalid_permission_decision} =
             Permission.respond(table, %{id: "approval", session_id: "session", principal: "user", decision: :other})

    assert {:ok, empty} = Permission.expire(table, "approval")
    assert empty.pending == %{}
    assert {:error, :stale_result} = Permission.expire(empty, "approval")
  end
end
