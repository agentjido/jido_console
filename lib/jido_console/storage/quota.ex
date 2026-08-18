defmodule Jido.Console.Storage.Quota do
  @moduledoc """
  Owns bounded state-tree accounting and high-water reservations.

  Reservations charge new source and destination high-water bytes before work
  enters the SQLite writer. Completion, rollback, caller failure, and expiry
  reconcile the reservation against the files that are present on disk.
  """

  use GenServer

  alias Jido.Console.Home
  alias Jido.Console.Storage.Quota.Journal

  @mib 1_024 * 1_024
  @limits %{
    active_database: 1_024 * @mib,
    wal: 384 * @mib,
    control_files: 16 * @mib,
    backups: 1_024 * @mib,
    archives: 512 * @mib,
    shared_work: 1_024 * @mib,
    structural_safety: 112 * @mib
  }
  @tree_limit 4_096 * @mib
  @normal_tree_limit 3_584 * @mib
  @normal_database_limit 864 * @mib
  @wal_normal_stop 64 * @mib
  @temporary_total_limit 64 * @mib
  @temporary_item_limit 16 * @mib
  @confirmed_page_limit 1 * @mib
  @confirmed_wal_limit 256 * @mib
  @confirmed_control_limit 8 * @mib
  @reservation_limit 128
  @inventory_limit 4_096
  @default_expiry_ms 30_000
  @result_limit 1_024
  @operation_id_limit 256
  @journal_reservation_bytes 1_024

  @budgets Map.keys(@limits)
  @reservable_budgets @budgets -- [:structural_safety]
  @control_operations [
    :cancellation,
    :safe_completion,
    :checkpoint_finalization,
    :recovery,
    :audit_export_metadata,
    :confirmed_session_removal,
    :confirmed_backup_retirement,
    :confirmed_quarantine_retirement,
    :shutdown
  ]
  @confirmed_operations [
    :confirmed_session_removal,
    :confirmed_backup_retirement,
    :confirmed_quarantine_retirement
  ]

  @type budget ::
          :active_database
          | :wal
          | :control_files
          | :backups
          | :archives
          | :shared_work
          | :structural_safety
  @type lane :: :normal | :control
  @type charges :: %{optional(budget()) => non_neg_integer() | map()}

  @doc "Starts the quota owner and reconciles the current state tree."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the exact state-tree and maintenance limits."
  @spec limits() :: map()
  def limits do
    %{
      budgets: @limits,
      tree_bytes: @tree_limit,
      normal_tree_bytes: @normal_tree_limit,
      maintenance_reserve_bytes: @tree_limit - @normal_tree_limit,
      normal_database_bytes: @normal_database_limit,
      database_control_reserve_bytes: @limits.active_database - @normal_database_limit,
      temporary_total_bytes: @temporary_total_limit,
      temporary_item_bytes: @temporary_item_limit,
      confirmed_removal: %{
        database_page_bytes: @confirmed_page_limit,
        wal_bytes: @confirmed_wal_limit,
        control_file_bytes: @confirmed_control_limit
      }
    }
  end

  @doc "Returns the closed set of operations that can use control capacity."
  @spec control_operations() :: [atom()]
  def control_operations, do: @control_operations

  @doc "Reserves one operation's additional source and destination high-water bytes."
  @spec reserve(GenServer.server(), String.t(), atom(), lane(), charges(), keyword()) ::
          {:ok, reference()} | {:error, term()}
  def reserve(server \\ __MODULE__, operation_id, operation_kind, lane, charges, opts \\ []) do
    GenServer.call(server, {:reserve, operation_id, operation_kind, lane, charges, opts})
  catch
    :exit, _reason -> {:error, :quota_unavailable}
  end

  @doc "Reconciles disk use and releases one exact reservation."
  @spec finish(GenServer.server(), reference(), :committed | :rolled_back | :cleaned_up) ::
          {:ok, map()} | {:error, term()}
  def finish(server \\ __MODULE__, token, outcome) do
    GenServer.call(server, {:finish, token, outcome})
  catch
    :exit, _reason -> {:error, :quota_unavailable}
  end

  @doc "Returns one bounded quota status without file paths or reservation payloads."
  @spec status(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _reason -> {:error, :quota_unavailable}
  end

  @doc "Looks up the latest result for one operation identity."
  @spec operation(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def operation(server \\ __MODULE__, operation_id) do
    GenServer.call(server, {:operation, operation_id})
  catch
    :exit, _reason -> {:error, :quota_unavailable}
  end

  @doc "Measures the state tree for diagnostics and deterministic tests."
  @spec inventory(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inventory(root, opts \\ []) when is_binary(root) do
    allocation_reader = Keyword.get(opts, :allocation_reader, &allocated_bytes/2)
    inventory_limit = Keyword.get(opts, :inventory_limit, @inventory_limit)

    with :ok <- validate_inventory_options(allocation_reader, inventory_limit),
         {:ok, usage, files, temporary_bytes, _entries} <-
           walk([{Path.expand(root), ""}], empty_usage(), 0, 0, 0, allocation_reader, inventory_limit) do
      {:ok,
       %{
         budgets: usage,
         files: files,
         temporary_bytes: temporary_bytes,
         tree_bytes: budget_total(usage)
       }}
    end
  end

  @impl true
  def init(opts) do
    with {:ok, root} <- root_path(opts),
         :ok <- prepare_root(root),
         allocation_reader = Keyword.get(opts, :allocation_reader, &allocated_bytes/2),
         available_reader = Keyword.get(opts, :available_bytes_reader, &available_bytes/1),
         inventory_limit = Keyword.get(opts, :inventory_limit, @inventory_limit),
         expiry_ms = Keyword.get(opts, :expiry_ms, @default_expiry_ms),
         :ok <- validate_inventory_options(allocation_reader, inventory_limit),
         :ok <- validate_available_reader(available_reader),
         :ok <- validate_expiry(expiry_ms),
         {:ok, available_bytes} <- available_reader.(root),
         :ok <- validate_available_bytes(available_bytes),
         {:ok, journal} <- Journal.load(root),
         {:ok, measured} <- inventory(root, allocation_reader: allocation_reader, inventory_limit: inventory_limit) do
      with {:ok, operations, operation_order} <- recover_journal(journal, measured) do
        state = %{
          root: root,
          allocation_reader: allocation_reader,
          available_reader: available_reader,
          inventory_limit: inventory_limit,
          expiry_ms: expiry_ms,
          usage: measured.budgets,
          files: measured.files,
          temporary_bytes: measured.temporary_bytes,
          available_bytes: available_bytes,
          reservations: %{},
          operations: operations,
          operation_order: operation_order
        }

        with :ok <- persist_journal(state), do: refresh(state)
      end
    end
  end

  @impl true
  def handle_call({:reserve, operation_id, kind, lane, charges, opts}, {caller, _tag}, state) do
    with :ok <- validate_operation(operation_id, kind, lane, state),
         {:ok, requested} <- normalize_charges(charges),
         {:ok, temporary_bytes} <- normalize_temporary(opts),
         {:ok, state} <- refresh(state),
         requested = Map.put(requested, :structural_safety, @journal_reservation_bytes),
         :ok <- validate_confirmed(kind, requested, opts, state),
         :ok <- admit(state, lane, requested, temporary_bytes) do
      token = make_ref()
      monitor = Process.monitor(caller)
      timer = Process.send_after(self(), {:expire, token}, state.expiry_ms)

      reservation = %{
        operation_id: operation_id,
        operation_kind: kind,
        lane: lane,
        requested: requested,
        temporary_bytes: temporary_bytes,
        caller: caller,
        monitor: monitor,
        timer: timer,
        orphaned?: false
      }

      state = clear_rolled_back_operation(state, operation_id)
      reserved_state = %{state | reservations: Map.put(state.reservations, token, reservation)}

      case persist_journal(reserved_state) do
        :ok ->
          case refresh(reserved_state) do
            {:ok, refreshed_state} ->
              {:reply, {:ok, token}, release_journal_headroom(refreshed_state, token)}

            {:error, _reason} = error ->
              {:reply, error, reserved_state}
          end

        {:error, _reason} = error ->
          Process.demonitor(monitor, [:flush])
          _cancelled = Process.cancel_timer(timer)
          {:reply, error, state}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:finish, token, outcome}, _from, state)
      when outcome in [:committed, :rolled_back, :cleaned_up] do
    finish_reservation(state, token, outcome)
  end

  def handle_call({:finish, _token, _outcome}, _from, state),
    do: {:reply, {:error, :invalid_quota_outcome}, state}

  def handle_call(:status, _from, state) do
    reserved = reserved_usage(state)

    {:reply,
     {:ok,
      %{
        files: state.files,
        usage: state.usage,
        measured_tree_bytes: budget_total(state.usage),
        measured_temporary_bytes: state.temporary_bytes,
        available_bytes: state.available_bytes,
        reserved: reserved,
        reserved_temporary_bytes: reserved_temporary(state),
        reserved_tree_bytes: budget_total(reserved),
        reservations: map_size(state.reservations),
        limits: limits()
      }}, state}
  end

  def handle_call({:operation, operation_id}, _from, state) do
    {:reply, lookup_operation(state, operation_id), state}
  end

  @impl true
  def handle_info({:expire, token}, state) do
    case finish_reservation(state, token, :expired) do
      {:reply, _result, state} ->
        {:noreply, state}

      {:retry, state} ->
        timer = Process.send_after(self(), {:expire, token}, state.expiry_ms)
        reservations = Map.update!(state.reservations, token, &%{&1 | timer: timer})
        {:noreply, %{state | reservations: reservations}}
    end
  end

  def handle_info({:DOWN, monitor, :process, caller, _reason}, state) do
    reservations =
      Map.new(state.reservations, fn
        {token, %{monitor: ^monitor, caller: ^caller} = reservation} ->
          {token, %{reservation | orphaned?: true}}

        entry ->
          entry
      end)

    {:noreply, %{state | reservations: reservations}}
  end

  defp finish_reservation(state, token, outcome) do
    case Map.fetch(state.reservations, token) do
      :error ->
        {:reply, {:error, :quota_reservation_not_found}, state}

      {:ok, reservation} ->
        case refresh(state) do
          {:ok, state} ->
            released_state = %{state | reservations: Map.delete(state.reservations, token)}
            result = operation_result(reservation, outcome, released_state)
            completed_state = put_operation(released_state, result)

            case persist_journal(completed_state) do
              :ok ->
                Process.demonitor(reservation.monitor, [:flush])
                _cancelled = Process.cancel_timer(reservation.timer)
                {:reply, {:ok, result}, completed_state}

              {:error, _reason} when outcome == :expired ->
                {:retry, state}

              {:error, _reason} = error ->
                {:reply, error, state}
            end

          {:error, _reason} when outcome == :expired ->
            {:retry, state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  defp operation_result(reservation, outcome, state) do
    %{
      operation_id: reservation.operation_id,
      operation_kind: reservation.operation_kind,
      lane: reservation.lane,
      outcome: outcome,
      orphaned: reservation.orphaned?,
      measured_tree_bytes: budget_total(state.usage),
      measured_budgets: state.usage,
      measured_temporary_bytes: state.temporary_bytes
    }
  end

  defp put_operation(state, %{operation_id: operation_id} = result) do
    order = [operation_id | List.delete(state.operation_order, operation_id)] |> Enum.take(@result_limit)
    operations = state.operations |> Map.put(operation_id, result) |> Map.take(order)
    %{state | operations: operations, operation_order: order}
  end

  defp persist_journal(state) do
    active =
      Enum.map(state.reservations, fn {_token, reservation} ->
        %{
          "operation_id" => reservation.operation_id,
          "operation_kind" => Atom.to_string(reservation.operation_kind),
          "lane" => Atom.to_string(reservation.lane),
          "requested" => encode_usage(reservation.requested),
          "temporary_bytes" => reservation.temporary_bytes,
          "orphaned" => reservation.orphaned?
        }
      end)

    operations =
      Enum.map(state.operation_order, fn operation_id ->
        operation = Map.fetch!(state.operations, operation_id)

        %{
          "operation_id" => operation.operation_id,
          "operation_kind" => Atom.to_string(operation.operation_kind),
          "lane" => Atom.to_string(operation.lane),
          "outcome" => Atom.to_string(operation.outcome),
          "orphaned" => operation.orphaned
        }
      end)

    Journal.write(state.root, %{
      "schema" => "jido.storage-quota",
      "schema_version" => 1,
      "active" => active,
      "operations" => operations
    })
  end

  defp release_journal_headroom(state, token) do
    reservations =
      Map.update!(state.reservations, token, fn reservation ->
        requested = Map.put(reservation.requested, :structural_safety, 0)
        %{reservation | requested: requested}
      end)

    %{state | reservations: reservations}
  end

  defp recover_journal(
         %{
           "schema" => "jido.storage-quota",
           "schema_version" => 1,
           "active" => active,
           "operations" => completed
         },
         measured
       )
       when is_list(active) and is_list(completed) do
    with {:ok, completed} <- decode_operations(completed, measured),
         {:ok, recovered} <- decode_recovered(active, measured) do
      results = Enum.take(recovered ++ completed, @result_limit)
      order = Enum.map(results, & &1.operation_id)

      if length(order) == length(Enum.uniq(order)) do
        {:ok, Map.new(results, &{&1.operation_id, &1}), order}
      else
        {:error, :duplicate_quota_journal_operation}
      end
    end
  end

  defp recover_journal(_journal, _measured), do: {:error, :invalid_quota_journal}

  defp decode_operations(operations, measured) do
    decode_journal_entries(operations, &decode_operation(&1, measured))
  end

  defp decode_recovered(active, measured) do
    decode_journal_entries(active, &decode_recovered_operation(&1, measured))
  end

  defp decode_journal_entries(entries, decoder) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, decoded} ->
      case decoder.(entry) do
        {:ok, result} -> {:cont, {:ok, [result | decoded]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end)
  end

  defp decode_operation(
         %{
           "operation_id" => operation_id,
           "operation_kind" => kind,
           "lane" => lane,
           "outcome" => outcome,
           "orphaned" => orphaned
         },
         measured
       ) do
    with :ok <- validate_journal_id(operation_id),
         {:ok, kind} <- existing_atom(kind),
         {:ok, lane} <- decode_member(lane, [:normal, :control]),
         {:ok, outcome} <- decode_member(outcome, [:committed, :rolled_back, :cleaned_up, :expired, :recovered]),
         true <- is_boolean(orphaned) do
      {:ok, recovered_result(operation_id, kind, lane, outcome, orphaned, measured)}
    else
      false -> {:error, :invalid_quota_journal_operation}
      {:error, _reason} = error -> error
    end
  end

  defp decode_operation(_operation, _measured), do: {:error, :invalid_quota_journal_operation}

  defp decode_recovered_operation(
         %{
           "operation_id" => operation_id,
           "operation_kind" => kind,
           "lane" => lane,
           "requested" => requested,
           "temporary_bytes" => temporary_bytes,
           "orphaned" => orphaned
         },
         measured
       ) do
    with :ok <- validate_journal_id(operation_id),
         {:ok, kind} <- existing_atom(kind),
         {:ok, lane} <- decode_member(lane, [:normal, :control]),
         {:ok, _requested} <- decode_usage(requested),
         true <- is_integer(temporary_bytes) and temporary_bytes >= 0,
         true <- is_boolean(orphaned) do
      {:ok, recovered_result(operation_id, kind, lane, :recovered, true, measured)}
    else
      false -> {:error, :invalid_quota_journal_reservation}
      {:error, _reason} = error -> error
    end
  end

  defp decode_recovered_operation(_operation, _measured),
    do: {:error, :invalid_quota_journal_reservation}

  defp recovered_result(operation_id, kind, lane, outcome, orphaned, measured) do
    %{
      operation_id: operation_id,
      operation_kind: kind,
      lane: lane,
      outcome: outcome,
      orphaned: orphaned,
      measured_tree_bytes: measured.tree_bytes,
      measured_budgets: measured.budgets,
      measured_temporary_bytes: measured.temporary_bytes
    }
  end

  defp validate_journal_id(value) when is_binary(value) and value != "", do: :ok
  defp validate_journal_id(_value), do: {:error, :invalid_quota_journal_operation_id}

  defp decode_member(value, allowed) when is_binary(value) do
    with {:ok, atom} <- existing_atom(value),
         true <- atom in allowed do
      {:ok, atom}
    else
      false -> {:error, :invalid_quota_journal_member}
      {:error, _reason} = error -> error
    end
  end

  defp decode_member(_value, _allowed), do: {:error, :invalid_quota_journal_member}

  defp existing_atom(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, :invalid_quota_journal_atom}
  end

  defp existing_atom(_value), do: {:error, :invalid_quota_journal_atom}

  defp encode_usage(usage) do
    Map.new(usage, fn {budget, bytes} -> {Atom.to_string(budget), bytes} end)
  end

  defp decode_usage(usage) when is_map(usage) do
    Enum.reduce_while(usage, {:ok, %{}}, fn {budget, bytes}, {:ok, decoded} ->
      with {:ok, budget} <- decode_member(budget, @budgets),
           true <- is_integer(bytes) and bytes >= 0 do
        {:cont, {:ok, Map.put(decoded, budget, bytes)}}
      else
        false -> {:halt, {:error, :invalid_quota_journal_usage}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp decode_usage(_usage), do: {:error, :invalid_quota_journal_usage}

  defp validate_operation(operation_id, kind, lane, state) do
    cond do
      not is_binary(operation_id) or operation_id == "" or byte_size(operation_id) > @operation_id_limit ->
        {:error, :quota_operation_id_required}

      not is_atom(kind) ->
        {:error, :invalid_quota_operation}

      lane not in [:normal, :control] ->
        {:error, :invalid_quota_lane}

      lane == :control and kind not in @control_operations ->
        {:error, {:quota_control_operation_denied, kind}}

      map_size(state.reservations) >= @reservation_limit ->
        {:error, {:quota_busy, :reservation_limit}}

      operation_present?(state, operation_id) ->
        {:error, {:quota_operation_exists, operation_id}}

      true ->
        :ok
    end
  end

  defp operation_present?(state, operation_id) do
    completed? =
      case Map.get(state.operations, operation_id) do
        nil -> false
        %{outcome: :rolled_back} -> false
        _operation -> true
      end

    completed? or
      Enum.any?(state.reservations, fn {_token, reservation} -> reservation.operation_id == operation_id end)
  end

  defp lookup_operation(state, operation_id) do
    case Map.fetch(state.operations, operation_id) do
      {:ok, operation} -> {:ok, operation}
      :error -> lookup_reservation(state.reservations, operation_id)
    end
  end

  defp lookup_reservation(reservations, operation_id) do
    reservation =
      Enum.find_value(reservations, fn {_token, reservation} ->
        if reservation.operation_id == operation_id, do: reservation
      end)

    if reservation do
      {:ok,
       %{
         operation_id: operation_id,
         operation_kind: reservation.operation_kind,
         lane: reservation.lane,
         outcome: :reserved,
         orphaned: reservation.orphaned?
       }}
    else
      {:error, {:quota_operation_not_found, operation_id}}
    end
  end

  defp clear_rolled_back_operation(state, operation_id) do
    case Map.get(state.operations, operation_id) do
      %{outcome: :rolled_back} ->
        %{
          state
          | operations: Map.delete(state.operations, operation_id),
            operation_order: List.delete(state.operation_order, operation_id)
        }

      _operation ->
        state
    end
  end

  defp normalize_charges(charges) when is_map(charges) do
    Enum.reduce_while(charges, {:ok, empty_usage()}, fn {budget, value}, {:ok, acc} ->
      with true <- budget in @reservable_budgets,
           {:ok, bytes} <- charge_bytes(value) do
        {:cont, {:ok, Map.update!(acc, budget, &(&1 + bytes))}}
      else
        false -> {:halt, {:error, {:invalid_quota_budget, budget}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_charges(_charges), do: {:error, :invalid_quota_charges}

  defp charge_bytes(bytes) when is_integer(bytes) and bytes >= 0, do: {:ok, bytes}

  defp charge_bytes(%{source_bytes: source, destination_bytes: destination})
       when is_integer(source) and source >= 0 and is_integer(destination) and destination >= 0,
       do: {:ok, source + destination}

  defp charge_bytes(_value), do: {:error, :invalid_quota_charge}

  defp normalize_temporary(opts) do
    items = Keyword.get(opts, :temporary_items, [])

    cond do
      not is_list(items) or Enum.any?(items, &(not is_integer(&1) or &1 < 0)) ->
        {:error, :invalid_temporary_reservation}

      Enum.any?(items, &(&1 > @temporary_item_limit)) ->
        {:error, {:quota_temporary_capacity, :item, @temporary_item_limit}}

      Enum.sum(items) > @temporary_total_limit ->
        {:error, {:quota_temporary_capacity, :aggregate, @temporary_total_limit}}

      true ->
        {:ok, Enum.sum(items)}
    end
  end

  defp validate_confirmed(kind, requested, opts, state) when kind in @confirmed_operations do
    page_bytes = Keyword.get(opts, :page_bytes, requested.active_database)
    wal_bytes = Keyword.get(opts, :wal_bytes, requested.wal)
    control_bytes = Keyword.get(opts, :control_file_bytes, requested.control_files)

    cond do
      state.usage.wal >= @wal_normal_stop ->
        {:error, {:quota_maintenance_capacity, :wal_start, state.usage.wal, @wal_normal_stop}}

      page_bytes > @confirmed_page_limit ->
        {:error, {:quota_maintenance_capacity, :database_pages, page_bytes, @confirmed_page_limit}}

      wal_bytes > @confirmed_wal_limit ->
        {:error, {:quota_maintenance_capacity, :wal, wal_bytes, @confirmed_wal_limit}}

      control_bytes > @confirmed_control_limit ->
        {:error, {:quota_maintenance_capacity, :control_files, control_bytes, @confirmed_control_limit}}

      true ->
        :ok
    end
  end

  defp validate_confirmed(_kind, _requested, _opts, _state), do: :ok

  defp admit(state, lane, requested, temporary_bytes) do
    reserved = reserved_usage(state)

    with :ok <- admit_budgets(state.usage, reserved, requested),
         :ok <- admit_database(state.usage, reserved, requested, lane),
         :ok <- admit_temporary(state, temporary_bytes),
         :ok <- admit_disk(state, requested) do
      admit_tree(state.usage, reserved, requested, lane)
    end
  end

  defp admit_temporary(state, temporary_bytes) do
    used = state.temporary_bytes + reserved_temporary(state)

    if used + temporary_bytes <= @temporary_total_limit,
      do: :ok,
      else: {:error, {:quota_temporary_capacity, :aggregate, used, temporary_bytes, @temporary_total_limit}}
  end

  defp admit_disk(state, requested) do
    reserved = state |> reserved_usage() |> budget_total()
    bytes = budget_total(requested)

    if reserved + bytes <= state.available_bytes,
      do: :ok,
      else: {:error, {:quota_disk_capacity, state.available_bytes, reserved, bytes}}
  end

  defp admit_budgets(usage, reserved, requested) do
    Enum.reduce_while(@budgets, :ok, fn budget, :ok ->
      used = usage[budget] + reserved[budget]
      bytes = requested[budget]
      limit = @limits[budget]

      if used + bytes <= limit do
        {:cont, :ok}
      else
        error =
          if budget == :wal,
            do: {:quota_wal_capacity, used, bytes, limit},
            else: {:quota_capacity, budget, used, bytes, limit}

        {:halt, {:error, error}}
      end
    end)
  end

  defp admit_database(usage, reserved, requested, :normal) do
    used = usage.active_database + reserved.active_database
    bytes = requested.active_database

    if used + bytes <= @normal_database_limit,
      do: :ok,
      else: {:error, {:quota_database_pages, :normal, used, bytes, @normal_database_limit}}
  end

  defp admit_database(_usage, _reserved, _requested, :control), do: :ok

  defp admit_tree(usage, reserved, requested, lane) do
    used = budget_total(usage) + budget_total(reserved)
    bytes = budget_total(requested)
    limit = if lane == :normal, do: @normal_tree_limit, else: @tree_limit

    if used + bytes <= limit,
      do: :ok,
      else: {:error, {:quota_tree_capacity, lane, used, bytes, limit}}
  end

  defp reserved_usage(state) do
    Enum.reduce(state.reservations, empty_usage(), fn {_token, reservation}, acc ->
      Map.new(acc, fn {budget, bytes} -> {budget, bytes + reservation.requested[budget]} end)
    end)
  end

  defp reserved_temporary(state) do
    Enum.reduce(state.reservations, 0, fn {_token, reservation}, bytes ->
      bytes + reservation.temporary_bytes
    end)
  end

  defp refresh(state) do
    with {:ok, available_bytes} <- state.available_reader.(state.root),
         :ok <- validate_available_bytes(available_bytes),
         {:ok, measured} <-
           inventory(state.root,
             allocation_reader: state.allocation_reader,
             inventory_limit: state.inventory_limit
           ) do
      {:ok,
       %{
         state
         | usage: measured.budgets,
           files: measured.files,
           temporary_bytes: measured.temporary_bytes,
           available_bytes: available_bytes
       }}
    end
  end

  defp root_path(opts) do
    case Keyword.get(opts, :root) do
      root when is_binary(root) and root != "" ->
        {:ok, Path.expand(root)}

      nil ->
        home_opts = Keyword.take(opts, [:jido_home, :user_home])

        with {:ok, _home} <- Home.ensure(home_opts),
             {:ok, state} <- Home.path(:state, home_opts) do
          {:ok, Path.join([state, "sessions", "v1"])}
        end

      root ->
        {:error, {:invalid_quota_root, root}}
    end
  end

  defp prepare_root(root) do
    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, Home.directory_mode()),
         {:ok, %{type: :directory}} <- File.lstat(root) do
      Home.check_private(root)
    else
      {:ok, %{type: type}} -> {:error, {:unsafe_quota_root, root, type}}
      {:error, reason} -> {:error, {:quota_root_unavailable, root, reason}}
    end
  end

  defp validate_inventory_options(reader, limit)
       when is_function(reader, 2) and is_integer(limit) and limit > 0,
       do: :ok

  defp validate_inventory_options(_reader, _limit), do: {:error, :invalid_quota_inventory_options}

  defp validate_available_reader(reader) when is_function(reader, 1), do: :ok
  defp validate_available_reader(_reader), do: {:error, :invalid_quota_available_reader}

  defp validate_available_bytes(bytes) when is_integer(bytes) and bytes >= 0, do: :ok
  defp validate_available_bytes(_bytes), do: {:error, :invalid_quota_available_bytes}

  defp validate_expiry(expiry_ms) when is_integer(expiry_ms) and expiry_ms > 0, do: :ok
  defp validate_expiry(_expiry_ms), do: {:error, :invalid_quota_expiry}

  defp walk(_pending, _usage, _files, _temporary, entries, _reader, limit) when entries > limit,
    do: {:error, {:quota_inventory_limit, entries, limit}}

  defp walk([], usage, files, temporary, entries, _reader, _limit),
    do: {:ok, usage, files, temporary, entries}

  defp walk([{path, relative} | pending], usage, files, temporary, entries, reader, limit) do
    entries = if relative == "", do: entries, else: entries + 1

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} ->
            children = inventory_children(path, relative, names)
            walk(children ++ pending, usage, files, temporary, entries, reader, limit)

          {:error, reason} ->
            {:error, {:quota_inventory_unavailable, path, reason}}
        end

      {:ok, %{type: :regular, size: logical}} ->
        accumulator = {pending, usage, files, temporary, entries}
        walk_regular(path, relative, logical, accumulator, reader, limit)

      {:ok, %{type: :symlink}} ->
        {:error, {:unsafe_quota_file, path, :symlink}}

      {:ok, %{type: type}} ->
        {:error, {:unsafe_quota_file, path, type}}

      {:error, :enoent} ->
        walk(pending, usage, files, temporary, entries, reader, limit)

      {:error, reason} ->
        {:error, {:quota_inventory_unavailable, path, reason}}
    end
  end

  defp inventory_children(path, relative, names) do
    names
    |> Enum.sort()
    |> Enum.map(fn name ->
      child_relative = if relative == "", do: name, else: Path.join(relative, name)
      {Path.join(path, name), child_relative}
    end)
  end

  defp walk_regular(
         path,
         relative,
         logical,
         {pending, usage, files, temporary, entries},
         reader,
         limit
       ) do
    case reader.(path, logical) do
      {:ok, allocated} when is_integer(allocated) and allocated >= 0 ->
        charged = max(logical, allocated)
        budget = classify(relative)
        temporary = if temporary_path?(relative), do: temporary + charged, else: temporary

        walk(
          pending,
          Map.update!(usage, budget, &(&1 + charged)),
          files + 1,
          temporary,
          entries,
          reader,
          limit
        )

      {:ok, _allocated} ->
        {:error, {:invalid_allocated_size, path}}

      {:error, reason} ->
        {:error, {:quota_allocation_unavailable, path, reason}}
    end
  end

  defp classify("console.sqlite3"), do: :active_database
  defp classify("console.sqlite3-wal"), do: :wal
  defp classify("console.sqlite3-journal"), do: :wal
  defp classify("quota-reservations.json"), do: :structural_safety
  defp classify("quota-reservations.json.tmp"), do: :structural_safety

  defp classify(relative) do
    first = relative |> Path.split() |> List.first()

    cond do
      first == "backups" -> :backups
      first == "archives" -> :archives
      first in ["staging", "quarantine", "repair", "tmp", "temporary"] -> :shared_work
      control_file?(relative) -> :control_files
      true -> :shared_work
    end
  end

  defp temporary_path?(relative) do
    first = relative |> Path.split() |> List.first()
    first in ["tmp", "temporary"] or String.ends_with?(relative, ".application.tmp")
  end

  defp control_file?(relative) do
    relative in [
      "console.sqlite3-shm",
      "home-lock.sqlite3",
      "home-lock.sqlite3-journal",
      "home-lock.sqlite3-wal",
      "home-lock.sqlite3-shm",
      "maintenance.json",
      "maintenance.json.tmp"
    ] or String.ends_with?(relative, [".manifest", ".tombstone"])
  end

  defp allocated_bytes(path, logical) do
    case :os.type() do
      {:unix, :darwin} -> stat_allocated("/usr/bin/stat", ["-f", "%b", path], 512, logical)
      {:unix, _name} -> stat_allocated("/usr/bin/stat", ["-c", "%b:%B", path], :reported, logical)
      _other -> {:ok, round_blocks(logical)}
    end
  end

  defp available_bytes(root) do
    case :os.type() do
      {:unix, _name} ->
        case System.cmd("/bin/df", ["-Pk", root], stderr_to_stdout: true) do
          {output, 0} -> parse_available(output)
          {_output, _status} -> {:error, :disk_capacity_unavailable}
        end

      _other ->
        {:ok, @tree_limit}
    end
  rescue
    _error -> {:error, :disk_capacity_unavailable}
  end

  defp parse_available(output) do
    fields =
      output
      |> String.split("\n", trim: true)
      |> List.last()
      |> String.split(~r/\s+/, trim: true)

    case fields do
      [_filesystem, _blocks, _used, available_kib | _rest] ->
        case Integer.parse(available_kib) do
          {available, ""} -> {:ok, available * 1_024}
          _other -> {:error, :invalid_disk_capacity}
        end

      _other ->
        {:error, :invalid_disk_capacity}
    end
  end

  defp stat_allocated(executable, args, multiplier, logical) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> parse_allocated(String.trim(output), multiplier)
      {_output, _status} -> {:ok, round_blocks(logical)}
    end
  rescue
    _error -> {:ok, round_blocks(logical)}
  end

  defp parse_allocated(output, :reported) do
    case String.split(output, ":", parts: 2) do
      [blocks, block_size] ->
        with {blocks, ""} <- Integer.parse(blocks),
             {block_size, ""} <- Integer.parse(block_size) do
          {:ok, blocks * block_size}
        else
          _other -> {:error, :invalid_stat_result}
        end

      _other ->
        {:error, :invalid_stat_result}
    end
  end

  defp parse_allocated(output, multiplier) when is_integer(multiplier) do
    case Integer.parse(output) do
      {blocks, ""} -> {:ok, blocks * multiplier}
      _other -> {:error, :invalid_stat_result}
    end
  end

  defp round_blocks(0), do: 0
  defp round_blocks(bytes), do: div(bytes + 4_095, 4_096) * 4_096

  defp empty_usage, do: Map.new(@budgets, &{&1, 0})
  defp budget_total(usage), do: usage |> Map.values() |> Enum.sum()
end
