defmodule Jido.Console.Error.Type do
  @moduledoc "Defines a project-owned Splode leaf error type."

  @doc "Adds the configured Splode error fields and redaction boundary."
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts) do
    class = Keyword.fetch!(opts, :class)
    fields = Keyword.fetch!(opts, :fields)
    default_message = Keyword.fetch!(opts, :default_message)

    field_names =
      Enum.map(fields, fn
        {name, _default} -> name
        name -> name
      end)

    quote do
      use Splode.Error,
        class: unquote(class),
        fields: unquote(Macro.escape(fields))

      @type t :: %__MODULE__{}

      @impl true
      def exception(opts) do
        opts
        |> Jido.Console.Error.prepare_options(
          unquote(default_message),
          unquote(field_names)
        )
        |> super()
      end
    end
  end
end

defmodule Jido.Console.Error do
  @moduledoc """
  The Splode error boundary for `Jido.Console`.

  All project errors are Splode leaf errors in one of four classes. This module
  converts raw subsystem and dependency failures into those errors before the
  CLI, JSONL writer, or session protocol shows them to a user.
  """

  use Splode,
    error_classes: [
      invalid: Jido.Console.Error.Invalid,
      config: Jido.Console.Error.Config,
      execution: Jido.Console.Error.Execution,
      internal: Jido.Console.Error.Internal
    ],
    unknown_error: __MODULE__.Internal.UnknownError,
    merge_with: [Jidoka.Error],
    filter_stacktraces: [__MODULE__, "Jido.Console.Error."]

  alias Jido.Console.Error

  @simple_reasons %{
    missing_agent: {Jido.Console.Error.InvalidInputError, "an --agent file is required for `jido run`"},
    choose_one_input_or_scenario:
      {Jido.Console.Error.InvalidInputError, "provide exactly one of --input or --scenario with `jido run`"},
    missing_suite: {Jido.Console.Error.InvalidInputError, "a suite file argument is required for `jido eval`"},
    request_expired:
      {Jido.Console.Error.InternalError,
       "The request was no longer available when Jido read the result. " <>
         "This is an internal request error. It does not mean that the API key is invalid. " <>
         "Try the prompt again. If the error occurs again, restart Jido."}
  }

  defmodule Invalid do
    @moduledoc "Invalid input, command, or argument errors."
    use Splode.ErrorClass, class: :invalid
  end

  defmodule Config do
    @moduledoc "File, directory, and configuration errors."
    use Splode.ErrorClass, class: :config
  end

  defmodule Execution do
    @moduledoc "Runtime execution errors."
    use Splode.ErrorClass, class: :execution
  end

  defmodule Internal do
    @moduledoc "Unexpected internal errors."
    use Splode.ErrorClass, class: :internal

    defmodule UnknownError do
      @moduledoc false

      use Jido.Console.Error.Type,
        class: :internal,
        fields: [message: nil, details: %{}, error: nil],
        default_message: "Unknown error"
    end
  end

  defmodule InvalidInputError do
    @moduledoc "Invalid command input or argument combinations."

    use Error.Type,
      class: :invalid,
      fields: [message: nil, details: %{}],
      default_message: "Invalid input"
  end

  defmodule InvalidJobsError do
    @moduledoc "An invalid `--jobs` value."

    use Error.Type,
      class: :invalid,
      fields: [message: nil, value: nil, details: %{}],
      default_message: "Invalid --jobs value"
  end

  defmodule UnknownCommandError do
    @moduledoc "An unrecognized automation command."

    use Error.Type,
      class: :invalid,
      fields: [message: nil, command: nil, details: %{}],
      default_message: "Unknown command"
  end

  defmodule UnexpectedArgumentsError do
    @moduledoc "Unexpected positional arguments."

    use Error.Type,
      class: :invalid,
      fields: [message: nil, arguments: nil, details: %{}],
      default_message: "Unexpected arguments"
  end

  defmodule InvalidOptionsError do
    @moduledoc "Invalid or unknown command-line options."

    use Error.Type,
      class: :invalid,
      fields: [message: nil, options: nil, details: %{}],
      default_message: "Invalid options"
  end

  defmodule ConfigurationError do
    @moduledoc "File, directory, or configuration problems."

    use Error.Type,
      class: :config,
      fields: [message: nil, details: %{}],
      default_message: "Configuration error"
  end

  defmodule OutputDirectoryNotEmptyError do
    @moduledoc "A requested output directory already has contents."

    use Error.Type,
      class: :config,
      fields: [message: nil, output_path: nil, entries: nil, details: %{}],
      default_message: "Output directory is not empty"
  end

  defmodule UnknownRuntimeProfileError do
    @moduledoc "A runtime profile name that the host did not register."

    use Error.Type,
      class: :config,
      fields: [message: nil, profile: nil, details: %{}],
      default_message: "Unknown runtime profile"
  end

  defmodule ExecutionFailureError do
    @moduledoc "A runtime execution failure."

    use Error.Type,
      class: :execution,
      fields: [message: nil, phase: nil, details: %{}],
      default_message: "Execution failed"
  end

  defmodule InternalError do
    @moduledoc "An unexpected internal failure."

    use Error.Type,
      class: :internal,
      fields: [message: nil, details: %{}],
      default_message: "Internal error"
  end

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

  @doc "Normalizes a reason into one project-owned Splode error."
  @spec normalize(term()) :: t()
  def normalize(reason)

  def normalize(%{__exception__: true, splode: __MODULE__} = error), do: error

  def normalize(%{__exception__: true} = exception) do
    normalize_exception(exception)
  end

  def normalize(message) when is_binary(message) do
    InternalError.exception(message: message)
  end

  def normalize(reason) when is_map_key(@simple_reasons, reason) do
    {module, message} = Map.fetch!(@simple_reasons, reason)
    module.exception(message: message)
  end

  def normalize(reason) when is_atom(reason) do
    ExecutionFailureError.exception(message: inspect(reason), details: %{reason: reason})
  end

  def normalize({:invalid_jobs, value}) do
    InvalidJobsError.exception(
      message: "--jobs must be a positive integer, got: #{inspect(redact(value))}",
      value: value
    )
  end

  def normalize({:unknown_automation_command, command}) do
    UnknownCommandError.exception(
      message: "unknown command: #{inspect(redact(command))}",
      command: command
    )
  end

  def normalize({:unexpected_arguments, arguments}) do
    UnexpectedArgumentsError.exception(
      message: "unexpected arguments: #{inspect(redact(arguments))}",
      arguments: arguments
    )
  end

  def normalize({:invalid_options, options}) do
    InvalidOptionsError.exception(
      message: "invalid options: #{format_options(options)}",
      options: options
    )
  end

  def normalize({:output_directory_not_empty, path, entries}) do
    OutputDirectoryNotEmptyError.exception(
      message: "output directory is not empty: #{redact(path)}",
      output_path: path,
      entries: entries
    )
  end

  def normalize({:output_directory_unavailable, path, reason}) do
    ConfigurationError.exception(
      message: "output directory is unavailable: #{redact(path)}: #{inspect(redact(reason))}",
      details: %{path: path, reason: reason}
    )
  end

  def normalize({:invalid_output_directory, value}) do
    ConfigurationError.exception(
      message: "invalid output directory: #{inspect(redact(value))}",
      details: %{value: value}
    )
  end

  def normalize({:unknown_runtime_profile, profile}) do
    UnknownRuntimeProfileError.exception(
      message: "unknown runtime profile: #{inspect(redact(profile))}",
      profile: profile
    )
  end

  def normalize(reason) do
    reason
    |> Jidoka.normalize_error(operation: :jido_console)
    |> normalize_exception()
  rescue
    _error -> ExecutionFailureError.exception(message: fallback_message(reason), details: %{reason: reason})
  end

  @doc "Returns a stable, redacted message for a reason."
  @spec message(term()) :: String.t()
  def message(reason), do: reason |> normalize() |> Exception.message()

  @doc "Returns the user-facing category of a normalized error."
  @spec category(term()) :: :validation | :configuration | :execution | :internal
  def category(reason) do
    case normalize(reason).class do
      :invalid -> :validation
      :config -> :configuration
      :execution -> :execution
      :internal -> :internal
    end
  end

  @doc "Returns a redacted, portable map for an error boundary."
  @spec to_map(term()) :: map()
  def to_map(reason) do
    reason
    |> normalize()
    |> error_map()
  end

  @doc false
  def prepare_options(opts, default_message, fields) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    fields
    |> Enum.reduce(Keyword.put_new(opts, :message, default_message), fn field, acc ->
      if Keyword.has_key?(acc, field) do
        Keyword.update!(acc, field, &redact/1)
      else
        acc
      end
    end)
    |> Keyword.update!(:message, fn message -> redact(message || default_message) end)
    |> Keyword.put_new(:details, %{})
    |> Keyword.put(:splode, __MODULE__)
  end

  @doc false
  def redact(value)

  def redact(%_{} = exception) when is_exception(exception) do
    %{
      exception: exception.__struct__ |> inspect(),
      message: exception |> Exception.message() |> redact()
    }
  end

  def redact(%_{} = struct), do: struct |> Map.from_struct() |> redact()

  def redact(%{} = map) do
    Map.new(map, fn {key, value} ->
      cond do
        sensitive_key?(key) -> {key, "[REDACTED]"}
        omitted_key?(key) -> {key, "[OMITTED]"}
        true -> {key, redact(value)}
      end
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)
  def redact(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&redact/1) |> List.to_tuple()

  def redact(value) when is_binary(value) do
    secret_patterns()
    |> Enum.reduce(value, fn {pattern, replacement}, text ->
      Regex.replace(pattern, text, replacement)
    end)
  end

  def redact(value), do: value

  defp normalize_exception(exception) do
    exception
    |> Jidoka.error_to_map()
    |> normalize_dependency_error(exception)
  rescue
    _error -> unknown_exception(exception)
  end

  defp normalize_dependency_error(error, exception) do
    category = fetch(error, :category)
    message = dependency_message(error, exception)
    details = dependency_details(error)

    case category do
      category when category in [:validation, "validation"] ->
        InvalidInputError.exception(message: message, details: details)

      category when category in [:configuration, "configuration"] ->
        ConfigurationError.exception(message: message, details: details)

      category when category in [:execution, "execution"] ->
        ExecutionFailureError.exception(message: message, phase: fetch(error, :phase), details: details)

      category when category in [:internal, "internal"] ->
        InternalError.exception(message: message, details: details)

      _category ->
        unknown_exception(exception)
    end
  end

  defp unknown_exception(exception) do
    Internal.UnknownError.exception(
      message: Exception.message(exception),
      details: %{exception: inspect(exception.__struct__)},
      error: exception
    )
  end

  defp dependency_message(error, exception) do
    message = fetch(error, :message)

    if generic_jidoka_execution_message?(message) do
      detailed_jidoka_message(error) || message
    else
      message || Exception.message(exception)
    end
  end

  defp dependency_details(error) do
    details = fetch(error, :details) || %{}

    details
    |> redact()
    |> Map.put_new(:category, fetch(error, :category))
    |> Map.put_new(:phase, fetch(error, :phase))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp generic_jidoka_execution_message?(message) when is_binary(message) do
    message |> String.trim() |> String.trim_trailing(".") == "Jidoka execution failed"
  end

  defp generic_jidoka_execution_message?(_message), do: false

  defp detailed_jidoka_message(error) do
    details = fetch(error, :details) || %{}
    find_detail_message(details) || cause_message(details, error)
  end

  defp find_detail_message(%{} = value) do
    message = fetch(value, :message)

    if useful_detail_message?(message) do
      message
    else
      [:cause, :error, :errors]
      |> Enum.find_value(fn key -> value |> fetch(key) |> find_detail_message() end)
      |> then(fn
        nil ->
          value
          |> Map.values()
          |> Enum.find_value(fn
            nested when is_map(nested) or is_list(nested) -> find_detail_message(nested)
            _nested -> nil
          end)

        nested_message ->
          nested_message
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
    cause = fetch(details, :cause)
    reason = cause_reason(cause)
    operation = fetch(details, :operation)
    phase = fetch(error, :phase)

    cond do
      not is_nil(reason) and operation in [:llm, "llm"] ->
        "The LLM request failed: #{reason_text(reason)}."

      not is_nil(reason) ->
        "Jidoka execution failed: #{reason_code(reason)}."

      operation in [:llm, "llm"] ->
        "The LLM request failed."

      not is_nil(phase) ->
        "Jidoka execution failed during the #{reason_text(phase)} phase."

      true ->
        nil
    end
  end

  defp cause_reason(reason) when is_atom(reason) and reason != :exception, do: reason
  defp cause_reason(reason) when is_binary(reason), do: reason

  defp cause_reason(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      tag when is_atom(tag) -> tag
      _tag -> nil
    end
  end

  defp cause_reason(_reason), do: nil

  defp reason_text(reason) when is_atom(reason), do: reason |> Atom.to_string() |> reason_text()
  defp reason_text(reason) when is_binary(reason), do: String.replace(reason, "_", " ")
  defp reason_text(reason), do: reason |> inspect() |> redact()

  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(reason) when is_binary(reason), do: reason

  defp fallback_message(reason) do
    reason
    |> Jidoka.Error.format()
    |> redact()
  rescue
    _error -> reason |> redact() |> inspect()
  end

  defp format_options(options) do
    options
    |> List.wrap()
    |> redact()
    |> Enum.map_join(", ", fn
      {key, value} -> "#{key} #{inspect(value)}"
      key -> inspect(key)
    end)
  end

  defp error_map(%module{errors: errors} = error) do
    if function_exported?(module, :error_class?, 0) and module.error_class?() do
      %{
        category: category(error),
        message: error |> Exception.message() |> redact(),
        errors: Enum.map(errors, &error_map/1)
      }
    else
      leaf_error_map(error)
    end
  end

  defp error_map(error), do: leaf_error_map(error)

  defp leaf_error_map(error) do
    [:phase, :field, :value, :details]
    |> Enum.reduce(
      %{category: category(error), message: error |> Exception.message() |> redact()},
      fn key, acc ->
        case Map.get(error, key) |> redact() do
          nil -> acc
          %{} = value when map_size(value) == 0 -> acc
          [] -> acc
          value -> Map.put(acc, key, value)
        end
      end
    )
  end

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp fetch(_value, _key), do: nil

  defp sensitive_key?(key), do: key_matches?(key, [:api_key, :authorization, :password, :secret, :token])
  defp omitted_key?(key), do: key_matches?(key, [:messages, :prompt, :raw_response, :request_body, :response_body])

  defp key_matches?(key, patterns) do
    key = key |> to_string() |> String.downcase()
    Enum.any?(patterns, &String.contains?(key, Atom.to_string(&1)))
  end

  # OTP 28 Regex values cannot be safely kept in module attributes when this
  # project is compiled with Elixir 1.18.
  defp secret_patterns do
    [
      {~r/sk-[A-Za-z0-9_-]{8,}/, "[REDACTED]"},
      {~r/(api[_-]?key|authorization|bearer|token|secret)(\s*[=:]\s*)\S+/i, "\\1\\2[REDACTED]"},
      {~r/Bearer\s+\S+/i, "Bearer [REDACTED]"}
    ]
  end
end
