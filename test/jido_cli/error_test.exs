defmodule Jido.Cli.ErrorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Jido.Cli.Error

  describe "normalize/1" do
    test "preserves a bare binary message verbatim" do
      assert Exception.message(Error.normalize("missing agent")) == "missing agent"
    end

    test "passes an existing exception through unchanged" do
      original = Error.validation_error("boom")
      assert Error.normalize(original) == original
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

      assert %Error.OutputDirectoryNotEmptyError{path: "/tmp/x", entries: ["a"]} =
               Error.normalize({:output_directory_not_empty, "/tmp/x", ["a"]})
    end

    test "falls back to an execution failure with a readable message" do
      normalized = Error.normalize({:some, :unknown, :reason})
      assert %Error.ExecutionFailureError{} = normalized
      assert is_binary(Exception.message(normalized))
    end
  end

  describe "helper constructors" do
    test "build the documented concrete errors" do
      assert %Error.InvalidInputError{} = Error.validation_error("nope")
      assert %Error.ConfigurationError{} = Error.config_error("bad config")
      assert %Error.ExecutionFailureError{} = Error.execution_error("boom")
      assert %Error.InternalError{} = Error.internal_error("oops")
    end
  end
end
