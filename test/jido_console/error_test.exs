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

    test "maps known automation reason terms to concrete errors with binary messages" do
      checks = [
        {:missing_agent, Error.InvalidInputError},
        {:choose_one_input_or_scenario, Error.InvalidInputError},
        {:missing_suite, Error.InvalidInputError},
        {{:invalid_jobs, 0}, Error.InvalidJobsError},
        {{:unknown_automation_command, ["compare"]}, Error.UnknownCommandError},
        {{:unexpected_arguments, ["extra"]}, Error.UnexpectedArgumentsError},
        {{:invalid_options, [{"--wat", nil}]}, Error.InvalidOptionsError},
        {{:output_directory_not_empty, "/tmp/x", ["a"]}, Error.OutputDirectoryNotEmptyError},
        {{:unknown_runtime_profile, "trusted"}, Error.UnknownRuntimeProfileError},
        {{:invalid_output_directory, 42}, Error.ConfigurationError},
        {{:output_directory_unavailable, "/tmp/x", :eacces}, Error.ConfigurationError}
      ]

      for {reason, module} <- checks do
        normalized = Error.normalize(reason)
        assert %^module{} = normalized, "expected #{inspect(module)} for #{inspect(reason)}"
        assert is_binary(Exception.message(normalized))
      end
    end

    test "carries structured fields through where they exist" do
      assert %Error.InvalidJobsError{value: 0} = Error.normalize({:invalid_jobs, 0})

      assert %Error.UnknownCommandError{command: ["compare"]} =
               Error.normalize({:unknown_automation_command, ["compare"]})

      assert %Error.OutputDirectoryNotEmptyError{output_path: "/tmp/x", entries: ["a"]} =
               Error.normalize({:output_directory_not_empty, "/tmp/x", ["a"]})
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
        Error.InvalidOptionsError.exception(
          message: "bad token=private-token",
          options: [api_key: "sk-secretvalue123"],
          details: %{prompt: "private prompt", authorization: "Bearer secret"}
        )

      encoded = inspect(error)

      assert Exception.message(error) == "bad token=[REDACTED]"
      refute encoded =~ "private-token"
      refute encoded =~ "secretvalue"
      refute encoded =~ "private prompt"
      refute encoded =~ "Bearer secret"
      assert error.options == [api_key: "[REDACTED]"]
      assert error.details == %{prompt: "[OMITTED]", authorization: "[REDACTED]"}
    end

    test "serializes one normalized project error shape" do
      assert Error.to_map({:invalid_jobs, 0}) == %{
               category: :validation,
               message: "--jobs must be a positive integer, got: 0",
               value: 0
             }
    end
  end
end
