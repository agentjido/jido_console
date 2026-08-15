defmodule Jido.Console.Error do
  @moduledoc """
  Centralized error handling for `Jido.Console` using Splode.

  This module classifies the failures the `jido` executable can report and gives
  each one a stable, human-readable message. Two kinds of submodules live here:

  * **Error classes** (`Invalid`, `Config`, `Execution`, `Internal`) exist for
    Splode classification and aggregation. Do not raise or match on them.
  * **Concrete exception structs** (ending in `Error`) are the values you raise,
    rescue, and pattern match on.

  The CLI normalizes every reason it receives — from the automation pipeline or
  from Jidoka — through `normalize/1` before printing it, so user-facing error
  text has one source of truth. The portable JSONL error map still delegates to
  Jidoka's normalizer, which owns rich provider and execution error data.
  """

  use Splode,
    error_classes: [
      invalid: Invalid,
      config: Config,
      execution: Execution,
      internal: Internal
    ],
    unknown_error: __MODULE__.Internal.UnknownError

  alias Jido.Console.Error

  # ---------------------------------------------------------------------------
  # Error class modules — classification only. Use the concrete errors below.
  # ---------------------------------------------------------------------------

  defmodule Invalid do
    @moduledoc "Invalid input, command, or argument error class for Splode."
    use Splode.ErrorClass, class: :invalid
  end

  defmodule Config do
    @moduledoc "Configuration error class for Splode."
    use Splode.ErrorClass, class: :config
  end

  defmodule Execution do
    @moduledoc "Execution error class for Splode."
    use Splode.ErrorClass, class: :execution
  end

  defmodule Internal do
    @moduledoc "Internal or unexpected error class for Splode."

    use Splode.ErrorClass, class: :internal

    defmodule UnknownError do
      @moduledoc false
      defexception [:message, :details]

      @type t :: %__MODULE__{message: String.t(), details: map()}

      @impl true
      def exception(opts) do
        %__MODULE__{
          message: Keyword.get(opts, :message, "Unknown error"),
          details: Keyword.get(opts, :details, %{})
        }
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Concrete exception structs — raise, rescue, and match on these.
  # ---------------------------------------------------------------------------

  defmodule InvalidInputError do
    @moduledoc "Error for invalid command input or argument combinations."
    defexception [:message, :details]

    @type t :: %__MODULE__{message: String.t(), details: map()}

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: Keyword.get(opts, :message, "Invalid input"),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  defmodule InvalidJobsError do
    @moduledoc "Error for an invalid `--jobs` value."
    defexception [:message, :value, :details]

    @type t :: %__MODULE__{message: String.t(), value: term(), details: map()}

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: Keyword.get(opts, :message, "Invalid --jobs value"),
        value: Keyword.get(opts, :value),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  defmodule UnknownCommandError do
    @moduledoc "Error for an unrecognized automation command."
    defexception [:message, :command, :details]

    @type t :: %__MODULE__{message: String.t(), command: term(), details: map()}

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: Keyword.get(opts, :message, "Unknown command"),
        command: Keyword.get(opts, :command),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  defmodule UnexpectedArgumentsError do
    @moduledoc "Error for unexpected positional arguments."
    defexception [:message, :arguments, :details]

    @type t :: %__MODULE__{message: String.t(), arguments: term(), details: map()}

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: Keyword.get(opts, :message, "Unexpected arguments"),
        arguments: Keyword.get(opts, :arguments),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  defmodule InvalidOptionsError do
    @moduledoc "Error for invalid or unknown command-line options."
    defexception [:message, :options, :details]

    @type t :: %__MODULE__{message: String.t(), options: term(), details: map()}

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: Keyword.get(opts, :message, "Invalid options"),
        options: Keyword.get(opts, :options),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  defmodule ConfigurationError do
    @moduledoc "Error for file, directory, or configuration problems."
    defexception [:message, :details]

    @type t :: %__MODULE__{message: String.t(), details: map()}

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: Keyword.get(opts, :message, "Configuration error"),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  defmodule OutputDirectoryNotEmptyError do
    @moduledoc "Error when a requested output directory already has contents."
    defexception [:message, :path, :entries, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            path: String.t() | nil,
            entries: term(),
            details: map()
          }

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: Keyword.get(opts, :message, "Output directory is not empty"),
        path: Keyword.get(opts, :path),
        entries: Keyword.get(opts, :entries),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  defmodule UnknownRuntimeProfileError do
    @moduledoc "Error for a runtime profile name the host did not register."
    defexception [:message, :profile, :details]

    @type t :: %__MODULE__{message: String.t(), profile: term(), details: map()}

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: Keyword.get(opts, :message, "Unknown runtime profile"),
        profile: Keyword.get(opts, :profile),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  defmodule ExecutionFailureError do
    @moduledoc "Error for runtime execution failures."
    defexception [:message, :details]

    @type t :: %__MODULE__{message: String.t(), details: map()}

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: Keyword.get(opts, :message, "Execution failed"),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  defmodule InternalError do
    @moduledoc "Error for unexpected internal failures."
    defexception [:message, :details]

    @type t :: %__MODULE__{message: String.t(), details: map()}

    @impl true
    def exception(opts) do
      %__MODULE__{
        message: Keyword.get(opts, :message, "Internal error"),
        details: Keyword.get(opts, :details, %{})
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Helper constructors.
  # ---------------------------------------------------------------------------

  @doc "Builds an invalid input error."
  @spec validation_error(String.t(), map()) :: InvalidInputError.t()
  def validation_error(message, details \\ %{}) do
    InvalidInputError.exception(message: message, details: details)
  end

  @doc "Builds a configuration error."
  @spec config_error(String.t(), map()) :: ConfigurationError.t()
  def config_error(message, details \\ %{}) do
    ConfigurationError.exception(message: message, details: details)
  end

  @doc "Builds an execution failure error."
  @spec execution_error(String.t(), map()) :: ExecutionFailureError.t()
  def execution_error(message, details \\ %{}) do
    ExecutionFailureError.exception(message: message, details: details)
  end

  @doc "Builds an internal error."
  @spec internal_error(String.t(), map()) :: InternalError.t()
  def internal_error(message, details \\ %{}) do
    InternalError.exception(message: message, details: details)
  end

  # ---------------------------------------------------------------------------
  # Normalization — single source of truth for user-facing error messages.
  # ---------------------------------------------------------------------------

  @doc """
  Normalizes a reason term into a `Jido.Console.Error` exception.

  Bare binaries are preserved verbatim so existing CLI output is unchanged.
  Known automation reason terms map to specific errors; everything else falls
  back to a best-effort message, deferring to `Jidoka.Error` when it can format
  the term.
  """
  @spec normalize(term()) :: Exception.t()
  def normalize(reason)

  def normalize(%{__exception__: true} = exception), do: expand_generic_jidoka_error(exception)

  def normalize(message) when is_binary(message),
    do: InternalError.exception(message: message)

  def normalize(:missing_agent),
    do: InvalidInputError.exception(message: "an --agent file is required for `jido run`")

  def normalize(:choose_one_input_or_scenario),
    do: InvalidInputError.exception(message: "provide exactly one of --input or --scenario with `jido run`")

  def normalize(:missing_suite),
    do: InvalidInputError.exception(message: "a suite file argument is required for `jido eval`")

  def normalize({:invalid_jobs, value}),
    do: InvalidJobsError.exception(message: "--jobs must be a positive integer, got: #{inspect(value)}", value: value)

  def normalize({:unknown_automation_command, command}),
    do:
      UnknownCommandError.exception(
        message: "unknown command: #{inspect(command)}",
        command: command
      )

  def normalize({:unexpected_arguments, arguments}),
    do:
      UnexpectedArgumentsError.exception(
        message: "unexpected arguments: #{inspect(arguments)}",
        arguments: arguments
      )

  def normalize({:invalid_options, options}),
    do:
      InvalidOptionsError.exception(
        message: "invalid options: #{format_options(options)}",
        options: options
      )

  def normalize({:output_directory_not_empty, path, entries}),
    do:
      OutputDirectoryNotEmptyError.exception(
        message: "output directory is not empty: #{path}",
        path: path,
        entries: entries
      )

  def normalize({:output_directory_unavailable, path, reason}),
    do:
      ConfigurationError.exception(
        message: "output directory is unavailable: #{path}: #{inspect(reason)}",
        details: %{path: path, reason: inspect(reason)}
      )

  def normalize({:invalid_output_directory, value}),
    do: ConfigurationError.exception(message: "invalid output directory: #{inspect(value)}", details: %{value: value})

  def normalize({:unknown_runtime_profile, profile}),
    do:
      UnknownRuntimeProfileError.exception(
        message: "unknown runtime profile: #{inspect(profile)}",
        profile: profile
      )

  def normalize(:request_expired) do
    InternalError.exception(
      message:
        "The request was no longer available when Jido read the result. " <>
          "This is an internal request error. It does not mean that the API key is invalid. " <>
          "Try the prompt again. If the error occurs again, restart Jido."
    )
  end

  def normalize(reason) do
    Error.ExecutionFailureError.exception(message: jidoka_message(reason))
  end

  defp expand_generic_jidoka_error(exception) do
    error = Jidoka.error_to_map(exception)
    message = Map.get(error, :message, Map.get(error, "message"))

    if generic_jidoka_execution_message?(message) do
      case detailed_jidoka_message(error) do
        nil -> exception
        detailed -> ExecutionFailureError.exception(message: detailed, details: safe_error_details(error))
      end
    else
      exception
    end
  rescue
    _exception -> exception
  end

  defp generic_jidoka_execution_message?(message) when is_binary(message) do
    message |> String.trim() |> String.trim_trailing(".") == "Jidoka execution failed"
  end

  defp generic_jidoka_execution_message?(_message), do: false

  defp detailed_jidoka_message(error) do
    details = Map.get(error, :details, Map.get(error, "details", %{}))

    find_detail_message(details) || cause_message(details, error)
  end

  defp find_detail_message(%{} = value) do
    message = Map.get(value, :message, Map.get(value, "message"))

    if useful_detail_message?(message) do
      message
    else
      [:cause, "cause", :error, "error", :errors, "errors"]
      |> Enum.find_value(fn key ->
        case Map.fetch(value, key) do
          {:ok, nested} -> find_detail_message(nested)
          :error -> nil
        end
      end)
      |> then(fn
        nil ->
          value
          |> Map.values()
          |> Enum.find_value(fn
            nested when is_map(nested) or is_list(nested) -> find_detail_message(nested)
            _nested -> nil
          end)

        message ->
          message
      end)
    end
  end

  defp find_detail_message(values) when is_list(values) do
    Enum.find_value(values, fn
      value when is_map(value) or is_list(value) -> find_detail_message(value)
      _value -> nil
    end)
  end

  defp find_detail_message(_value), do: nil

  defp useful_detail_message?(message) when is_binary(message) do
    String.trim(message) != "" and not generic_jidoka_execution_message?(message)
  end

  defp useful_detail_message?(_message), do: false

  defp cause_message(details, error) do
    cause = Map.get(details, :cause, Map.get(details, "cause"))
    reason = cause_reason(cause)
    operation = Map.get(details, :operation, Map.get(details, "operation"))
    phase = Map.get(error, :phase, Map.get(error, "phase"))

    cond do
      not is_nil(reason) and operation == :llm ->
        "The LLM request failed: #{reason_text(reason)}."

      not is_nil(reason) ->
        "Jidoka execution failed: #{reason_text(reason)}."

      operation == :llm ->
        "The LLM request failed."

      not is_nil(phase) and is_atom(phase) ->
        "Jidoka execution failed during the #{reason_text(phase)} phase."

      true ->
        nil
    end
  end

  defp cause_reason(reason) when is_atom(reason) and reason != :exception, do: reason

  defp cause_reason(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      tag when is_atom(tag) -> tag
      _tag -> nil
    end
  end

  defp cause_reason(_reason), do: nil

  defp safe_error_details(error) do
    details = Map.get(error, :details, Map.get(error, "details", %{}))
    cause = Map.get(details, :cause, Map.get(details, "cause"))

    %{
      category: Map.get(error, :category, Map.get(error, "category")),
      phase: Map.get(error, :phase, Map.get(error, "phase")),
      operation: Map.get(details, :operation, Map.get(details, "operation")),
      cause: cause_reason(cause)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp reason_text(reason) do
    reason
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp format_options(options) do
    options
    |> List.wrap()
    |> Enum.map_join(", ", fn
      {key, value} -> "#{key} #{inspect(value)}"
      key -> inspect(key)
    end)
  end

  defp jidoka_message(reason) do
    Jidoka.Error.format(reason)
  rescue
    _ -> inspect(reason)
  end
end
