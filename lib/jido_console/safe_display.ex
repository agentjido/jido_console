defmodule Jido.Console.SafeDisplay do
  @moduledoc "Projects private errors as bounded, terminal-safe public data."

  alias Jido.Console.Error
  alias Jido.Console.Terminal.PlainText

  @display_limit 200
  @generic_codes %{
    validation: "invalid_input",
    configuration: "configuration_error",
    execution: "execution_failure",
    internal: "internal_error"
  }

  @doc "Returns one stable public error code."
  @spec code(term()) :: String.t()
  def code(reason) do
    case reason_code(reason) || normalized_reason_code(reason) do
      code when is_binary(code) -> code
      nil -> Map.fetch!(@generic_codes, category(reason))
    end
  end

  @doc "Returns one cleaned public error message."
  @spec message(term()) :: String.t()
  def message(reason) do
    reason
    |> code()
    |> message_for(category(reason))
    |> clean()
  end

  @doc "Returns the only error data allowed in public views and events."
  @spec to_map(term()) :: %{String.t() => String.t()}
  def to_map(reason), do: %{"code" => code(reason), "message" => message(reason)}

  @doc "Cleans one value for a public single-line display."
  @spec clean(term()) :: String.t()
  def clean(value) do
    value
    |> PlainText.summary(@display_limit * 2)
    |> String.replace(bidirectional_controls(), "")
    |> String.slice(0, @display_limit)
  end

  @doc "Returns the public display limit in graphemes."
  @spec limit() :: pos_integer()
  def limit, do: @display_limit

  defp category(reason) do
    Error.category(reason)
  rescue
    _exception -> :internal
  catch
    _kind, _reason -> :internal
  end

  defp reason_code({:session_attach_failed, reason}), do: reason_code(reason)
  defp reason_code({:resume_blocked, _reason}), do: "resume_blocked"

  defp reason_code(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    reason
    |> Tuple.to_list()
    |> Enum.find_value(&reason_code/1)
  end

  defp reason_code(reason) when is_list(reason), do: Enum.find_value(reason, &reason_code/1)

  defp reason_code(reason) when is_atom(reason) do
    reason
    |> Atom.to_string()
    |> allow_code()
  end

  defp reason_code(%{"code" => code}) when is_binary(code), do: allow_code(code)
  defp reason_code(%{code: code}) when is_binary(code), do: allow_code(code)
  defp reason_code(_reason), do: nil

  defp allow_code(code) do
    if public_code?(code), do: code, else: nil
  end

  defp public_code?(code) do
    String.starts_with?(code, [
      "agent_source_",
      "binding_",
      "conflicting_",
      "consent_",
      "execution_policy_",
      "invalid_agent_",
      "invalid_binding_",
      "invalid_coding_",
      "invalid_execution_",
      "invalid_interactive_",
      "invalid_model_",
      "invalid_operation_",
      "process_store_",
      "recovery_",
      "repeated_",
      "reserved_context_",
      "runtime_definition_",
      "stored_",
      "unknown_execution_",
      "unknown_model",
      "unknown_provider",
      "unknown_runtime_",
      "write_"
    ]) or
      code in [
        "coding_module_name_forbidden",
        "credential_argument_rejected",
        "dotenv_permissions_too_open",
        "empty_model_policy",
        "home_locked",
        "local_coding_root_required",
        "resume_blocked",
        "storage_schema_backup_exists",
        "storage_schema_backup_failed",
        "storage_schema_reset_required",
        "timeout_unknown",
        "unsupported_agent_source_format",
        "unsupported_store_schema"
      ]
  end

  defp message_for(code, _category) when code in ["agent_source_missing", "agent_source_not_regular"],
    do: "Jido could not read the selected agent source."

  defp message_for(code, _category) when code in ["agent_source_symlink", "agent_source_changed"],
    do: "The selected agent source did not pass the file identity check."

  defp message_for(code, _category) when code in ["agent_source_too_large", "agent_source_heap_limit_exceeded"],
    do: "The selected agent source is larger than the allowed limit."

  defp message_for(code, _category)
       when code in [
              "agent_source_invalid_utf8",
              "agent_source_admission_rejected",
              "invalid_agent_source",
              "unsupported_agent_source_format"
            ],
       do: "Jido could not use the selected agent source."

  defp message_for("agent_source_deadline_exceeded", _category),
    do: "The selected agent source did not load before the safety deadline."

  defp message_for("conflicting_execution_policy_inputs", _category),
    do: "Use only one execution-policy input name in this input layer."

  defp message_for(code, _category) when code in ["repeated_execution_policy_input", "repeated_interactive_option"],
    do: "An interactive option was supplied more than once."

  defp message_for("consent_required", _category),
    do: "This execution policy needs an explicit user choice before work can start."

  defp message_for("execution_policy_mismatch", _category),
    do: "The selected policy does not match the policy requested by the agent."

  defp message_for("execution_policy_root_required", _category),
    do: "This execution policy needs an explicit workspace root."

  defp message_for(code, _category)
       when code in ["execution_policy_root_mismatch", "invalid_execution_policy_root"],
       do: "The workspace does not match the selected execution policy."

  defp message_for("unknown_execution_policy", _category),
    do: "The selected execution policy is not registered by this host."

  defp message_for("execution_policy_consent_origin_forbidden", _category),
    do: "The caller cannot set an execution-policy consent origin."

  defp message_for("binding_locked", _category),
    do: "Agent, model, and execution-policy selections are locked for this thread."

  defp message_for("binding_conflict", _category),
    do: "The requested selection does not match the stored thread binding."

  defp message_for("resume_blocked", _category),
    do: "Jido cannot resume this thread because its stored binding is no longer exact."

  defp message_for("home_locked", _category),
    do: "Another Jido process is using the local console database. Close it or use a different Jido home."

  defp message_for("storage_schema_backup_exists", _category),
    do: "An old Jido database backup already exists. Move it before startup."

  defp message_for("storage_schema_backup_failed", _category),
    do: "Jido could not preserve the old database. Startup stopped without replacing it."

  defp message_for("storage_schema_reset_required", _category),
    do: "Jido must replace the old database before startup."

  defp message_for("unsupported_store_schema", _category),
    do: "This Jido database uses an unsupported storage version."

  defp message_for("invalid_operation_arguments", _category),
    do: "A coding tool received invalid arguments. Try the task again."

  defp message_for(code, :validation) when code != "invalid_input", do: "The input is not valid (#{code})."

  defp message_for(code, :configuration) when code != "configuration_error",
    do: "Jido could not use this configuration (#{code})."

  defp message_for(code, :execution) when code != "execution_failure",
    do: "Jido could not complete the request (#{code})."

  defp message_for(code, :internal) when code != "internal_error",
    do: "Jido stopped because of an internal error (#{code})."

  defp message_for(_code, :validation), do: "The input is not valid."
  defp message_for(_code, :configuration), do: "Jido could not use this configuration."
  defp message_for(_code, :execution), do: "Jido could not complete the request."
  defp message_for(_code, :internal), do: "Jido stopped because of an internal error."

  defp normalized_reason_code(reason) do
    case Error.normalize(reason) do
      %Error.ExecutionFailureError{details: %{reason: :invalid_operation_arguments}} ->
        "invalid_operation_arguments"

      _error ->
        nil
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  # OTP 28 Regex values must not be stored in module attributes with Elixir 1.18.
  defp bidirectional_controls, do: ~r/[\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u
end
