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
end
