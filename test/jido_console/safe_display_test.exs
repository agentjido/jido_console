defmodule Jido.Console.SafeDisplayTest do
  use ExUnit.Case, async: true

  alias Jido.Console.SafeDisplay

  test "projects source errors without private diagnostics" do
    path = "/private/work/agent.yaml"
    secret = "token=secret-value"
    fragment = "instructions: erase everything"
    reason = {:agent_source_admission_rejected, path, secret, fragment}

    assert %{"code" => "agent_source_admission_rejected", "message" => message} =
             SafeDisplay.to_map(reason)

    refute message =~ path
    refute message =~ "secret-value"
    refute message =~ "erase everything"
  end

  test "removes terminal and bidirectional controls and bounds graphemes" do
    unsafe = "\e]0;private\a\e[31m" <> String.duplicate("界", 240) <> "\u202Ehidden\nnext"
    cleaned = SafeDisplay.clean(unsafe)

    refute cleaned =~ "\e"
    refute cleaned =~ "\u202E"
    refute cleaned =~ "\n"
    assert String.length(cleaned) <= SafeDisplay.limit()
  end

  test "finds a stable safe code inside an OTP startup reason" do
    reason =
      {:jido_console,
       {:shutdown,
        {:failed_to_start_child, :storage, {:storage_schema_backup_exists, "/private/db", "/private/backup"}}}}

    assert SafeDisplay.code(reason) == "storage_schema_backup_exists"
    refute SafeDisplay.message(reason) =~ "/private"
  end

  test "does not show arbitrary exception text" do
    message = SafeDisplay.message(RuntimeError.exception("api_key=private source fragment"))
    refute message =~ "private"
    refute message =~ "source fragment"
  end

  test "keeps private diagnostics only in the internal host error" do
    path = "/private/work/agent.yaml"
    reason = {:agent_source_admission_rejected, path, "token=private"}
    internal = Jido.Console.Error.normalize(reason)

    assert inspect(internal.details) =~ path
    refute SafeDisplay.message(reason) =~ path
  end

  test "uses stable messages for policy, binding, storage, and source errors" do
    cases = [
      {:agent_source_missing, "could not read"},
      {:agent_source_symlink, "identity check"},
      {:agent_source_too_large, "allowed limit"},
      {:agent_source_invalid_utf8, "could not use"},
      {:agent_source_deadline_exceeded, "safety deadline"},
      {{:consent_required, "coding.trusted-workspace"}, "explicit user choice"},
      {{:execution_policy_mismatch, "requested", "selected"}, "does not match"},
      {{:execution_policy_root_required, "coding.trusted-workspace"}, "workspace root"},
      {{:execution_policy_root_mismatch, "/private"}, "workspace does not match"},
      {{:binding_locked, "thread"}, "selections are locked"},
      {{:binding_conflict, :model}, "stored thread binding"},
      {{:home_locked, "/private"}, "local console database"},
      {{:storage_schema_backup_failed, "/private", "/backup", :reason}, "preserve the old database"},
      {{:storage_schema_reset_required, "/private", 1, []}, "replace the old database"},
      {{:unsupported_store_schema, "/private", 2, []}, "unsupported storage version"}
    ]

    for {reason, expected} <- cases do
      message = SafeDisplay.message(reason)
      assert message =~ expected
      refute message =~ "/private"
    end
  end

  test "uses safe generic messages for each host error category" do
    cases = [
      {Jido.Console.Error.validation_error("private validation"), "The input is not valid."},
      {Jido.Console.Error.config_error("private configuration"), "Jido could not use this configuration."},
      {Jido.Console.Error.execution_error("private execution"), "Jido could not complete the request."},
      {Jido.Console.Error.internal_error("private internal"), "Jido stopped because of an internal error."}
    ]

    for {reason, expected} <- cases do
      assert SafeDisplay.message(reason) == expected
    end
  end

  test "uses the operation-specific safe message" do
    reason = {:invalid_operation_arguments, "coding.write", %{message: "private"}}
    assert SafeDisplay.message(reason) == "A coding tool received invalid arguments. Try the task again."
  end
end
