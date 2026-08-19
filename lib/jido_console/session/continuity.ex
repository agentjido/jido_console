defmodule Jido.Console.Session.Continuity do
  @moduledoc """
  Frozen v0.3 durable-continuity contract.

  This module exposes the versioned record inventory, acknowledgement rules,
  fences, watermarks, recovery states, operation matrix, file-only boundary,
  hard limits, crash points, and qualification profile. It does not open a
  store, recover a session, or grant execution authority.
  """

  @schema_name "jido.continuity.v1.json"
  @schema_source Path.expand("../../../priv/session/continuity/#{@schema_name}", __DIR__)
  @external_resource @schema_source
  @schema_contents File.read!(@schema_source)
  @required_sections ~w(
    storage
    records
    acknowledgements
    generation_fence
    watermark
    recovery_lifecycle
    operations
    limits
    crash_points
    qualification_profile
  )
  @record_classes ~w(authoritative derived process_local sensitive forbidden)
  @durability_classes ~w(durable process forbidden)

  @type contract :: map()
  @type result(value) :: {:ok, value} | {:error, term()}

  @doc "Loads the continuity contract embedded at compile time or from an explicit path."
  @spec schema(keyword()) :: result(contract())
  def schema(opts \\ []) do
    opts
    |> contents(:path, @schema_contents)
    |> decode(:continuity_contract_invalid, :continuity_contract_unreadable)
  end

  @doc "Returns the installed continuity-contract path."
  @spec schema_path() :: Path.t()
  def schema_path, do: priv_path(@schema_name)

  @doc "Returns all declared records."
  @spec records(contract()) :: [map()]
  def records(%{"records" => records}) when is_list(records), do: records
  def records(_contract), do: []

  @doc "Returns one declared record by name."
  @spec record(contract(), String.t()) :: result(map())
  def record(contract, name) when is_binary(name) do
    find_named(records(contract), name, :unknown_continuity_record)
  end

  @doc "Returns all acknowledgement rules."
  @spec acknowledgements(contract()) :: [map()]
  def acknowledgements(%{"acknowledgements" => rules}) when is_list(rules), do: rules
  def acknowledgements(_contract), do: []

  @doc "Returns one acknowledgement rule by item."
  @spec acknowledgement(contract(), String.t()) :: result(map())
  def acknowledgement(contract, item) when is_binary(item) do
    find_named(acknowledgements(contract), item, :unknown_acknowledgement, "item")
  end

  @doc "Returns one operation rule by name."
  @spec operation(contract(), String.t()) :: result(map())
  def operation(%{"operations" => operations}, name) when is_list(operations) and is_binary(name) do
    find_named(operations, name, :unknown_continuity_operation)
  end

  def operation(_contract, name), do: {:error, {:unknown_continuity_operation, name}}

  @doc "Validates one declared watermark transition."
  @spec validate_watermark_transition(contract(), String.t(), String.t()) :: :ok | {:error, term()}
  def validate_watermark_transition(contract, from, to) when is_binary(from) and is_binary(to) do
    transitions = get_in(contract, ["watermark", "transitions"]) || []

    if [from, to] in transitions do
      :ok
    else
      {:error, {:invalid_watermark_transition, from, to}}
    end
  end

  @doc "Returns one hard limit by name."
  @spec limit(contract(), String.t()) :: result(number())
  def limit(%{"limits" => limits}, name) when is_map(limits) and is_binary(name) do
    case Map.fetch(limits, name) do
      {:ok, value} when is_number(value) -> {:ok, value}
      _other -> {:error, {:unknown_continuity_limit, name}}
    end
  end

  def limit(_contract, name), do: {:error, {:unknown_continuity_limit, name}}

  @doc "Reviews the frozen contract for missing or ambiguous ownership and bounds."
  @spec review(contract()) :: :ok | {:error, [term()]}
  def review(contract) when is_map(contract) do
    defects =
      []
      |> review_identity(contract)
      |> review_sections(contract)
      |> review_records(contract)
      |> review_acknowledgements(contract)
      |> review_limits(contract)

    if defects == [], do: :ok, else: {:error, Enum.reverse(defects)}
  end

  def review(_contract), do: {:error, [:invalid_continuity_contract]}

  defp contents(opts, key, embedded) do
    case Keyword.fetch(opts, key) do
      {:ok, path} -> File.read(path)
      :error -> {:ok, embedded}
    end
  end

  defp decode({:ok, contents}, invalid, _unreadable) do
    case Jason.decode(contents) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, invalid}
      {:error, reason} -> {:error, {invalid, reason}}
    end
  end

  defp decode({:error, reason}, _invalid, unreadable), do: {:error, {unreadable, reason}}

  defp priv_path(name) do
    :jido_console
    |> :code.priv_dir()
    |> List.to_string()
    |> Path.join("session/continuity/#{name}")
  end

  defp find_named(values, name, error, field \\ "name") do
    case Enum.find(values, &(&1[field] == name)) do
      nil -> {:error, {error, name}}
      value -> {:ok, value}
    end
  end

  defp review_identity(defects, contract) do
    defects
    |> maybe_add(contract["contract"] != "jido.continuity", :continuity_identity_invalid)
    |> maybe_add(contract["version"] != "1", :continuity_version_invalid)
  end

  defp review_sections(defects, contract) do
    missing = Enum.reject(@required_sections, &Map.has_key?(contract, &1))
    maybe_add(defects, missing != [], {:continuity_sections_missing, missing})
  end

  defp review_records(defects, contract) do
    declared = records(contract)

    invalid? =
      Enum.any?(declared, fn record ->
        not is_binary(record["name"]) or record["name"] == "" or
          not is_binary(record["owner"]) or record["owner"] == "" or
          record["class"] not in @record_classes or record["durability"] not in @durability_classes
      end)

    defects
    |> maybe_add(declared == [], :continuity_records_missing)
    |> maybe_add(invalid?, :continuity_record_invalid)
    |> maybe_add(duplicate_values(declared, "name") != [], :continuity_record_duplicate)
  end

  defp review_acknowledgements(defects, contract) do
    rules = acknowledgements(contract)

    invalid? =
      Enum.any?(rules, fn rule ->
        not is_binary(rule["item"]) or not is_binary(rule["durable_operation"]) or
          not is_list(rule["required_records"])
      end)

    defects
    |> maybe_add(rules == [], :continuity_acknowledgements_missing)
    |> maybe_add(invalid?, :continuity_acknowledgement_invalid)
    |> maybe_add(duplicate_values(rules, "item") != [], :continuity_acknowledgement_duplicate)
  end

  defp review_limits(defects, contract) do
    limits = contract["limits"] || %{}
    invalid? = map_size(limits) == 0 or Enum.any?(limits, fn {_name, value} -> not is_number(value) or value <= 0 end)
    maybe_add(defects, invalid?, :continuity_limits_invalid)
  end

  defp duplicate_values(values, field) do
    values
    |> Enum.map(& &1[field])
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
  end

  defp maybe_add(defects, true, defect), do: [defect | defects]
  defp maybe_add(defects, false, _defect), do: defects
end
