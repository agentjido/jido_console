defmodule Jido.Console.ErrorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Jido.Console.Error

  describe "normalize/1" do
    test "preserves a bare binary message verbatim" do
      assert Exception.message(Error.normalize("missing agent")) == "missing agent"
    end

    test "passes an existing project Splode error through unchanged" do
      original = Error.validation_error("boom")
      assert Error.normalize(original) == original
      assert Error.splode_error?(original)
      assert original.splode == Error
      assert original.class == :invalid
    end

    test "shows the sanitized provider cause in a generic Jidoka execution error" do
      cause =
        ReqLLM.Error.API.Request.exception(
          reason: "bad key sk-secretvalue123",
          status: 401
        )

      jidoka_error = Jidoka.normalize_error(cause, operation: :llm, phase: :effect)
      normalized = Error.normalize(jidoka_error)
      message = Exception.message(normalized)

      assert %Error.ExecutionFailureError{} = normalized
      assert message == "API request failed (401): bad key [REDACTED]"
      refute message =~ "secretvalue"
    end

    test "shows a safe reason when a generic Jidoka error has no cause message" do
      jidoka_error =
        Jidoka.normalize_error(
          {:invalid_provider_message, %{messages: ["private prompt"], api_key: "sk-secretvalue123"}},
          operation: :llm,
          phase: :effect
        )

      normalized = Error.normalize(jidoka_error)

      assert Exception.message(normalized) ==
               "The LLM request failed: invalid provider message."

      refute inspect(normalized.details) =~ "private prompt"
      refute inspect(normalized.details) =~ "secretvalue"
    end

    test "maps a known configuration reason to a concrete error" do
      assert %Error.UnknownRuntimeProfileError{profile: "trusted"} =
               Error.normalize({:unknown_runtime_profile, "trusted"})
    end

    test "finds a storage backup failure inside an OTP application startup error" do
      database = "/private/jido/state/console.sqlite3"
      backup = database <> ".schema-1-backup"

      reason =
        {:jido_console,
         {{:shutdown,
           {:failed_to_start_child, Jido.Console.Storage.Supervisor,
            {:shutdown,
             {:failed_to_start_child, Jido.Console.Storage.SQLite, {:storage_schema_backup_exists, database, backup}}}}},
          {Jido.Console.Application, :start, [:normal, []]}}}

      assert %Error.ConfigurationError{} = normalized = Error.normalize(reason)

      assert Exception.message(normalized) ==
               "Old Jido database backup already exists at #{backup}. Move it before startup."
    end

    test "gives clear messages for other storage schema startup failures" do
      database = "/private/jido/state/console.sqlite3"
      backup = database <> ".schema-1-backup"

      cases = [
        {{:storage_schema_backup_failed, database, backup, :eacces}, "could not preserve the old database"},
        {{:storage_schema_reset_required, database, 1, ["events"]}, "must replace the old database"},
        {{:unsupported_store_schema, database, 9, ["sessions"]}, "version 9 is not supported"}
      ]

      Enum.each(cases, fn {reason, expected} ->
        nested = {:jido_console, {:shutdown, {:failed_to_start_child, Jido.Console.Storage.SQLite, reason}}}
        assert %Error.ConfigurationError{} = normalized = Error.normalize(nested)
        assert Exception.message(normalized) =~ expected
      end)
    end

    test "falls back to an execution failure with a readable message" do
      normalized = Error.normalize({:some, :unknown, :reason})
      assert %Error.ExecutionFailureError{} = normalized
      assert normalized.class == :execution
      assert normalized.splode == Error
      assert is_binary(Exception.message(normalized))
    end

    test "wraps a non-Splode exception in the project internal class" do
      normalized = Error.normalize(RuntimeError.exception("failed"))

      assert %Error.Internal.UnknownError{} = normalized
      assert normalized.class == :internal
      assert normalized.splode == Error
      assert Exception.message(normalized) == "failed"
    end

    test "maps every dependency class into a project class" do
      cases = [
        {Jidoka.Error.validation_error("invalid"), Error.InvalidInputError, :validation},
        {Jidoka.Error.config_error("bad config"), Error.ConfigurationError, :configuration},
        {Jidoka.Error.execution_error("failed"), Error.ExecutionFailureError, :execution},
        {Jidoka.Error.Internal.UnknownError.exception(message: "unknown"), Error.InternalError, :internal}
      ]

      Enum.each(cases, fn {reason, module, category} ->
        assert %^module{} = normalized = Error.normalize(reason)
        assert Error.category(normalized) == category
        assert Error.message(normalized) != ""
      end)

      assert %Error.ExecutionFailureError{} = Error.normalize(:unmapped_atom)
    end

    test "extracts useful messages from nested Jidoka execution details" do
      cases = [
        {%{errors: [:ignored, %{message: "nested failure"}]}, nil, "nested failure"},
        {%{cause: :timeout, operation: :operation}, nil, "Jidoka execution failed: timeout."},
        {%{operation: :llm}, nil, "The LLM request failed."},
        {%{}, :output, "Jidoka execution failed during the output phase."},
        {%{cause: {"not-an-atom", :reason}}, nil, "Jidoka execution failed"}
      ]

      Enum.each(cases, fn {details, phase, expected} ->
        reason =
          Jidoka.Error.ExecutionError.exception(
            message: "Jidoka execution failed",
            phase: phase,
            details: details
          )

        assert Exception.message(Error.normalize(reason)) =~ expected
      end)
    end

    test "derives safe messages from tuple, portable, phase, and empty causes" do
      cases = [
        {%{cause: {:timeout, :late}, operation: :llm}, nil, "timeout"},
        {%{cause: %{type: "tuple", values: [:rate_limited, "private"]}}, nil, "rate_limited"},
        {%{}, 42, "42"},
        {%{}, nil, "Jidoka execution failed"}
      ]

      for {details, phase, expected} <- cases do
        reason =
          Jidoka.Error.ExecutionError.exception(message: "Jidoka execution failed", phase: phase, details: details)

        assert Error.message(reason) =~ expected
      end
    end

    test "explains an expired request and separates it from API-key errors" do
      normalized = Error.normalize(:request_expired)
      message = Exception.message(normalized)

      assert %Error.InternalError{} = normalized
      assert message =~ "internal request error"
      assert message =~ "does not mean that the API key is invalid"
      assert message =~ "Try the prompt again"
    end
  end

  describe "helper constructors" do
    test "build the documented concrete errors" do
      assert %Error.InvalidInputError{} = Error.validation_error("nope")
      assert %Error.ConfigurationError{} = Error.config_error("bad config")
      assert %Error.ExecutionFailureError{} = Error.execution_error("boom")
      assert %Error.InternalError{} = Error.internal_error("oops")
    end

    test "aggregates project leaf errors with the configured Splode class" do
      aggregate = Error.to_class([Error.validation_error("first"), Error.validation_error("second")])

      assert %Error.Invalid{class: :invalid, splode: Error} = aggregate
      assert Enum.map(aggregate.errors, &Exception.message/1) == ["first", "second"]
      assert Enum.all?(aggregate.errors, &Error.splode_error?/1)
    end
  end

  describe "redaction and portable errors" do
    test "redacts messages and all structured fields at construction" do
      error =
        Error.ExecutionFailureError.exception(
          message: "bad token=private-token",
          phase: [api_key: "sk-secretvalue123"],
          details: %{prompt: "private prompt", authorization: "Bearer secret"}
        )

      encoded = inspect(error)

      assert Exception.message(error) == "bad token=[REDACTED]"
      refute encoded =~ "private-token"
      refute encoded =~ "secretvalue"
      refute encoded =~ "private prompt"
      refute encoded =~ "Bearer secret"
      assert error.phase == [api_key: "[REDACTED]"]
      assert error.details == %{prompt: "[OMITTED]", authorization: "[REDACTED]"}
    end

    test "redacts structs and tuples and serializes aggregate errors" do
      assert Error.redact(%URI{scheme: "https", host: "example.test"}) == %{
               authority: nil,
               fragment: nil,
               host: "example.test",
               path: nil,
               port: nil,
               query: nil,
               scheme: "https",
               userinfo: nil
             }

      assert Error.redact({:ok, %{api_key: "private"}}) == {:ok, %{api_key: "[REDACTED]"}}

      aggregate = Error.to_class([Error.validation_error("first"), Error.validation_error("second")])

      mapped = Error.to_map(aggregate)
      assert mapped.category == :validation
      assert mapped.message =~ "first"

      assert mapped.errors == [
               %{category: :validation, message: "first"},
               %{category: :validation, message: "second"}
             ]

      assert %Error.InvalidInputError{} = Error.InvalidInputError.exception(%{message: nil})
    end

    test "keeps safe primitive data and omits empty portable fields" do
      assert Error.redact(123) == 123

      mapped =
        Error.ExecutionFailureError.exception(message: "failed", details: %{}, phase: nil)
        |> Error.to_map()

      refute Map.has_key?(mapped, :details)
      refute Map.has_key?(mapped, :phase)
    end
  end
end
