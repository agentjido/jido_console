defmodule Jido.Console.Session.Durable.Migration do
  @moduledoc "Ordered, deterministic, checksum-identified migration contract without storage I/O."

  @type version :: non_neg_integer()
  @type ledger_entry :: %{
          id: String.t(),
          source_version: version(),
          target_version: version(),
          checksum: String.t(),
          status: :applied
        }
  @type result :: %{
          status: :current | :migrated,
          source_version: version(),
          target_version: version(),
          value: map(),
          ledger: [ledger_entry()]
        }

  @callback id() :: String.t()
  @callback source_version() :: version()
  @callback target_version() :: version()
  @callback checksum() :: String.t()
  @callback transform(map()) :: {:ok, map()} | {:error, term()}

  @doc "Runs the exact ordered migration path, or returns a non-mutating compatibility result."
  @spec run(map(), version(), version(), [module()]) :: {:ok, result()} | {:error, term()}
  def run(value, source_version, target_version, steps \\ [])

  def run(value, version, version, _steps) when is_map(value) and is_integer(version) and version >= 0 do
    {:ok,
     %{
       status: :current,
       source_version: version,
       target_version: version,
       value: value,
       ledger: []
     }}
  end

  def run(value, source_version, target_version, steps)
      when is_map(value) and is_integer(source_version) and is_integer(target_version) and is_list(steps) do
    cond do
      source_version > target_version ->
        {:error, {:incompatible_future_store_format, source_version, target_version}}

      source_version < 0 or target_version < 0 ->
        {:error, :invalid_store_format_version}

      true ->
        migrate(value, source_version, target_version, steps, source_version, [])
    end
  end

  def run(_value, _source_version, _target_version, _steps), do: {:error, :invalid_migration_input}

  @doc "Checks step identity, deterministic output, and second-run idempotence."
  @spec conform(module(), map()) :: :ok | {:error, term()}
  def conform(step, fixture) when is_atom(step) and is_map(fixture) do
    source = step.source_version()
    target = step.target_version()

    with :ok <- validate_step(step, source),
         {:ok, first} <- step.transform(fixture),
         {:ok, second} <- step.transform(fixture),
         true <- first == second,
         {:ok, migrated} <- run(fixture, source, target, [step]),
         {:ok, current} <- run(migrated.value, target, target, [step]),
         true <- current.value == migrated.value and current.ledger == [] do
      :ok
    else
      false -> {:error, {:nondeterministic_or_non_idempotent_migration, step}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:invalid_migration_step, step, exception}}
  end

  defp migrate(value, target, target, _steps, source, ledger) do
    {:ok,
     %{
       status: :migrated,
       source_version: source,
       target_version: target,
       value: value,
       ledger: Enum.reverse(ledger)
     }}
  end

  defp migrate(value, version, target, steps, source, ledger) do
    case Enum.find(steps, &(safe_source_version(&1) == version)) do
      nil ->
        {:error, {:missing_migration_step, version, target}}

      step ->
        case validate_step(step, version) do
          :ok -> apply_step(value, version, target, steps, source, ledger, step)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp apply_step(value, version, target, steps, source, ledger, step) do
    with {:ok, migrated} <- step.transform(value),
         true <- is_map(migrated) do
      entry = %{
        id: step.id(),
        source_version: version,
        target_version: step.target_version(),
        checksum: step.checksum(),
        status: :applied
      }

      migrate(migrated, step.target_version(), target, steps, source, [entry | ledger])
    else
      false -> {:error, {:invalid_migration_result, step}}
      {:error, reason} -> {:error, {:migration_failed, step.id(), reason}}
    end
  end

  defp validate_step(step, expected_source) do
    cond do
      not valid_step_module?(step) -> {:error, {:invalid_migration_step, step}}
      not non_empty?(step.id()) -> {:error, {:invalid_migration_id, step}}
      step.source_version() != expected_source -> {:error, {:migration_source_mismatch, step}}
      step.target_version() != expected_source + 1 -> {:error, {:migration_order_invalid, step}}
      not valid_checksum?(step.checksum()) -> {:error, {:migration_checksum_invalid, step}}
      true -> :ok
    end
  end

  defp valid_step_module?(step) do
    Enum.all?(
      [id: 0, source_version: 0, target_version: 0, checksum: 0, transform: 1],
      fn {name, arity} -> function_exported?(step, name, arity) end
    )
  end

  defp safe_source_version(step) do
    if function_exported?(step, :source_version, 0), do: step.source_version(), else: nil
  rescue
    _exception -> nil
  end

  defp valid_checksum?("sha256:" <> checksum),
    do: byte_size(checksum) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, checksum)

  defp valid_checksum?(_checksum), do: false
  defp non_empty?(value), do: is_binary(value) and value != ""
end
