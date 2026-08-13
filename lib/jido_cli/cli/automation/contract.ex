defmodule Jido.Cli.Automation.Contract do
  @moduledoc "Validates versioned automation JSONL records and run artifacts."

  alias Jido.Cli.Automation.Contract.Schema

  @type kind :: :case_result | :manifest | :summary | :lifecycle
  @type validation_error :: {:invalid_automation_contract, kind(), term()}

  @doc "Returns the strict version 1 case-result schema."
  defdelegate case_result_schema(), to: Schema

  @doc "Returns the strict version 1 run-manifest schema."
  defdelegate manifest_schema(), to: Schema

  @doc "Returns the strict version 1 run-summary schema."
  defdelegate summary_schema(), to: Schema

  @doc "Returns the strict version 1 run-lifecycle schema."
  defdelegate lifecycle_schema(), to: Schema

  @doc "Returns the strict turn schema used by case-result version 1."
  defdelegate turn_schema(), to: Schema

  @doc "Returns the strict execution schema used by case-result version 1."
  defdelegate execution_schema(), to: Schema

  @doc "Returns the additive execution-environment schema used by case-result version 1."
  defdelegate execution_environment_schema(), to: Schema

  @doc "Returns the additive capability-replay evidence schema."
  defdelegate capability_replay_schema(), to: Schema

  @doc "Returns the additive automation runtime-limit evidence schema."
  defdelegate runtime_limits_schema(), to: Schema

  @doc "Returns the strict cell-evaluation schema used by case-result version 1."
  defdelegate evaluation_schema(), to: Schema

  @doc "Returns the strict assertion schema used by turn records."
  defdelegate assertion_schema(), to: Schema

  @doc "Returns the strict usage schema used by case and turn records."
  defdelegate usage_schema(), to: Schema

  @doc "Returns the strict portable-error schema used by case and turn records."
  defdelegate error_schema(), to: Schema

  @doc "Returns the strict matrix-dimensions schema."
  defdelegate dimensions_schema(), to: Schema

  @doc "Returns the strict source-provenance schema."
  defdelegate sources_schema(), to: Schema

  @doc "Validates and normalizes one producer case-result record."
  @spec validate_case_result(term()) :: {:ok, map()} | {:error, validation_error()}
  def validate_case_result(value), do: validate(:case_result, Schema.case_result_schema(), value)

  @doc "Validates and normalizes one producer run manifest."
  @spec validate_manifest(term()) :: {:ok, map()} | {:error, validation_error()}
  def validate_manifest(value), do: validate(:manifest, Schema.manifest_schema(), value)

  @doc "Validates and normalizes one producer run summary."
  @spec validate_summary(term()) :: {:ok, map()} | {:error, validation_error()}
  def validate_summary(value), do: validate(:summary, Schema.summary_schema(), value)

  @doc "Validates and normalizes one producer run lifecycle."
  @spec validate_lifecycle(term()) :: {:ok, map()} | {:error, validation_error()}
  def validate_lifecycle(value), do: validate(:lifecycle, Schema.lifecycle_schema(), value)

  @doc "Reads a version 1 case result and ignores unknown optional fields."
  @spec read_case_result(term()) :: {:ok, map()} | {:error, validation_error()}
  def read_case_result(value), do: validate(:case_result, Schema.case_result_schema(:strip), value)

  @doc "Reads a version 1 run manifest and ignores unknown optional fields."
  @spec read_manifest(term()) :: {:ok, map()} | {:error, validation_error()}
  def read_manifest(value), do: validate(:manifest, Schema.manifest_schema(:strip), value)

  @doc "Reads a version 1 run summary and ignores unknown optional fields."
  @spec read_summary(term()) :: {:ok, map()} | {:error, validation_error()}
  def read_summary(value), do: validate(:summary, Schema.summary_schema(:strip), value)

  @doc "Reads a version 1 run lifecycle and ignores unknown optional fields."
  @spec read_lifecycle(term()) :: {:ok, map()} | {:error, validation_error()}
  def read_lifecycle(value), do: validate(:lifecycle, Schema.lifecycle_schema(:strip), value)

  @doc "Validates a case-result record and raises for an internal producer bug."
  @spec case_result!(term()) :: map()
  def case_result!(value), do: validate!(validate_case_result(value))

  @doc "Validates a run manifest and raises for an internal producer bug."
  @spec manifest!(term()) :: map()
  def manifest!(value), do: validate!(validate_manifest(value))

  @doc "Validates a run summary and raises for an internal producer bug."
  @spec summary!(term()) :: map()
  def summary!(value), do: validate!(validate_summary(value))

  @doc "Validates a run lifecycle and raises for an internal producer bug."
  @spec lifecycle!(term()) :: map()
  def lifecycle!(value), do: validate!(validate_lifecycle(value))

  defp validate(kind, schema, value) do
    with {:ok, portable} <- portable(value),
         {:ok, parsed} <- Zoi.parse(schema, portable),
         {:ok, _json} <- Jason.encode(parsed) do
      {:ok, parsed}
    else
      {:error, reason} -> {:error, {:invalid_automation_contract, kind, reason}}
    end
  end

  defp validate!({:ok, value}), do: value

  defp validate!({:error, reason}) do
    raise ArgumentError, "invalid automation producer data: #{inspect(reason)}"
  end

  defp portable(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp portable(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp portable(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, items} ->
      case portable(item) do
        {:ok, portable_item} -> {:cont, {:ok, [portable_item | items]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp portable(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, items} ->
      with {:ok, portable_key} <- portable_key(key),
           false <- Map.has_key?(items, portable_key),
           {:ok, portable_item} <- portable(item) do
        {:cont, {:ok, Map.put(items, portable_key, portable_item)}}
      else
        true -> {:halt, {:error, {:duplicate_json_key, key}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp portable(value), do: {:error, {:non_json_value, value}}

  defp portable_key(key) when is_binary(key), do: {:ok, key}
  defp portable_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp portable_key(key), do: {:error, {:non_json_map_key, key}}
end
