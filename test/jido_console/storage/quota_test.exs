defmodule Jido.Console.Storage.QuotaTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.Durable.CanonicalJSON
  alias Jido.Console.Storage.Quota

  @mib 1_024 * 1_024

  setup do
    root = Path.join(System.tmp_dir!(), "jido-quota-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, name: unique(:quota)}
  end

  test "declares seven exact budgets and one closed control operation set" do
    assert %{
             budgets: budgets,
             tree_bytes: 4_294_967_296,
             normal_tree_bytes: 3_758_096_384,
             maintenance_reserve_bytes: 536_870_912,
             normal_database_bytes: 905_969_664,
             database_control_reserve_bytes: 167_772_160,
             temporary_total_bytes: 67_108_864,
             temporary_item_bytes: 16_777_216,
             confirmed_removal: %{
               database_page_bytes: 1_048_576,
               wal_bytes: 268_435_456,
               control_file_bytes: 8_388_608
             }
           } = Quota.limits()

    assert budgets == %{
             active_database: 1_073_741_824,
             wal: 402_653_184,
             control_files: 16_777_216,
             backups: 1_073_741_824,
             archives: 536_870_912,
             shared_work: 1_073_741_824,
             structural_safety: 117_440_512
           }

    assert Enum.sum(Map.values(budgets)) == 4_294_967_296

    assert Quota.control_operations() == [
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
  end

  test "classifies every owned file and charges the larger measured allocation", %{root: root} do
    write(root, "console.sqlite3", "db")
    write(root, "console.sqlite3-wal", "wal")
    write(root, "console.sqlite3-shm", "shm")
    write(root, "backups/one.sqlite3", "backup")
    write(root, "archives/one.jsonl", "archive")
    write(root, "staging/one.tmp", "stage")
    write(root, "unknown.bin", "unknown")

    allocation_reader = fn path, logical ->
      if Path.basename(path) == "console.sqlite3", do: {:ok, 100}, else: {:ok, logical}
    end

    assert {:ok, %{files: 7, budgets: usage, tree_bytes: total}} =
             Quota.inventory(root, allocation_reader: allocation_reader)

    assert usage.active_database == 100
    assert usage.wal == 3
    assert usage.control_files == 3
    assert usage.backups == 6
    assert usage.archives == 7
    assert usage.shared_work == 12
    assert usage.structural_safety == 0
    assert total == Enum.sum(Map.values(usage))
  end

  test "charges sparse files by logical size and rejects symbolic links", %{root: root} do
    path = Path.join(root, "staging/sparse.bin")
    File.mkdir_p!(Path.dirname(path))
    {:ok, io} = :file.open(String.to_charlist(path), [:write, :raw, :binary])
    {:ok, _position} = :file.position(io, 8 * @mib - 1)
    :ok = :file.write(io, <<0>>)
    :ok = :file.close(io)

    assert {:ok, %{budgets: %{shared_work: charged}}} = Quota.inventory(root)
    assert charged >= 8 * @mib

    link = Path.join(root, "staging/link")
    File.ln_s!(path, link)
    assert {:error, {:unsafe_quota_file, ^link, :symlink}} = Quota.inventory(root)
  end

  test "reserves the exact normal high-water boundary and keeps the tree reserve", %{
    root: root,
    name: name
  } do
    assert {:ok, _pid} = start_quota(name, root)
    assert {:ok, %{measured_tree_bytes: baseline}} = Quota.status(name)

    exact = %{
      active_database: %{source_bytes: 0, destination_bytes: 864 * @mib},
      wal: 384 * @mib,
      control_files: 16 * @mib,
      backups: 1_024 * @mib,
      archives: 512 * @mib,
      shared_work: 784 * @mib - baseline - 1_024
    }

    assert {:ok, token} = Quota.reserve(name, "normal-exact", :backup, :normal, exact)

    assert {:ok, %{outcome: :reserved}} = Quota.operation(name, "normal-exact")

    reserved = 3_758_096_384 - baseline - 1_024

    assert {:ok, %{measured_tree_bytes: measured, reserved_tree_bytes: ^reserved}} = Quota.status(name)
    used = measured + reserved

    assert {:error, {:quota_tree_capacity, :normal, ^used, 1_025, 3_758_096_384}} =
             Quota.reserve(name, "normal-over", :normal_write, :normal, %{shared_work: 1})

    assert {:ok, %{measured_tree_bytes: ^measured, reserved_tree_bytes: ^reserved, reservations: 1}} =
             Quota.status(name)

    assert {:ok, %{outcome: :rolled_back}} = Quota.finish(name, token, :rolled_back)
    assert {:ok, %{reservations: 0}} = Quota.status(name)
  end

  test "returns typed sub-budget, database, and temporary capacity results", %{root: root, name: name} do
    assert {:ok, _pid} = start_quota(name, root)

    assert {:error, {:quota_capacity, :backups, 0, bytes, 1_073_741_824}} =
             Quota.reserve(name, "backup-over", :backup, :normal, %{backups: 1_024 * @mib + 1})

    assert bytes == 1_024 * @mib + 1

    assert {:error, {:quota_database_pages, :normal, 0, bytes, 905_969_664}} =
             Quota.reserve(name, "database-over", :normal_write, :normal, %{
               active_database: 864 * @mib + 1
             })

    assert bytes == 864 * @mib + 1

    assert {:error, {:quota_wal_capacity, 0, bytes, 402_653_184}} =
             Quota.reserve(name, "wal-over", :normal_write, :normal, %{wal: 384 * @mib + 1})

    assert bytes == 384 * @mib + 1

    assert {:error, {:quota_temporary_capacity, :item, 16_777_216}} =
             Quota.reserve(name, "temp-item", :backup, :normal, %{shared_work: 1}, temporary_items: [16 * @mib + 1])

    assert {:error, {:quota_temporary_capacity, :aggregate, 67_108_864}} =
             Quota.reserve(name, "temp-total", :backup, :normal, %{shared_work: 1},
               temporary_items: List.duplicate(16 * @mib, 4) ++ [1]
             )

    assert {:error, {:invalid_quota_budget, :structural_safety}} =
             Quota.reserve(name, "safety", :backup, :normal, %{structural_safety: 1})
  end

  test "includes measured application temporary files in the aggregate limit", %{root: root, name: name} do
    write(root, "tmp/existing", "x")

    allocation_reader = fn path, logical ->
      if Path.basename(path) == "existing", do: {:ok, 60 * @mib}, else: {:ok, logical}
    end

    assert {:ok, _pid} =
             Quota.start_link(name: name, root: root, allocation_reader: allocation_reader)

    measured = 60 * @mib
    requested = 5 * @mib
    limit = 64 * @mib

    assert {:error, {:quota_temporary_capacity, :aggregate, ^measured, ^requested, ^limit}} =
             Quota.reserve(name, "temp-measured", :normal_write, :normal, %{shared_work: 5 * @mib},
               temporary_items: [5 * @mib]
             )
  end

  test "allows control capacity only for declared bounded operations", %{root: root, name: name} do
    assert {:ok, _pid} = start_quota(name, root)

    assert {:error, {:quota_control_operation_denied, :backup}} =
             Quota.reserve(name, "denied-control", :backup, :control, %{shared_work: 1})

    assert {:error, {:quota_maintenance_capacity, :database_pages, bytes, 1_048_576}} =
             Quota.reserve(
               name,
               "large-removal-pages",
               :confirmed_session_removal,
               :control,
               %{active_database: 1},
               page_bytes: 1 * @mib + 1
             )

    assert bytes == 1 * @mib + 1

    assert {:error, {:quota_maintenance_capacity, :wal, bytes, 268_435_456}} =
             Quota.reserve(
               name,
               "large-removal-wal",
               :confirmed_backup_retirement,
               :control,
               %{wal: 1},
               wal_bytes: 256 * @mib + 1
             )

    assert bytes == 256 * @mib + 1

    assert {:ok, token} =
             Quota.reserve(
               name,
               "bounded-removal",
               :confirmed_quarantine_retirement,
               :control,
               %{active_database: 1 * @mib, wal: 256 * @mib, control_files: 8 * @mib},
               page_bytes: 1 * @mib,
               wal_bytes: 256 * @mib,
               control_file_bytes: 8 * @mib
             )

    assert {:ok, %{outcome: :cleaned_up}} = Quota.finish(name, token, :cleaned_up)
  end

  test "requires confirmed removal to start below the normal WAL stop", %{root: root, name: name} do
    wal = write(root, "console.sqlite3-wal", "wal")

    allocation_reader = fn path, logical ->
      if path == wal, do: {:ok, 64 * @mib}, else: {:ok, logical}
    end

    assert {:ok, _pid} = start_quota(name, root, allocation_reader: allocation_reader)

    assert {:error, {:quota_maintenance_capacity, :wal_start, bytes, 67_108_864}} =
             Quota.reserve(
               name,
               "wal-start-blocked",
               :confirmed_session_removal,
               :control,
               %{active_database: 1},
               page_bytes: 1
             )

    assert bytes == 64 * @mib
  end

  test "permits retry after rollback and returns typed unavailability", %{root: root, name: name} do
    assert {:error, :quota_unavailable} = Quota.status(unique(:missing))
    assert {:ok, _pid} = start_quota(name, root)
    assert {:ok, token} = Quota.reserve(name, "retryable", :normal_write, :normal, %{wal: 1})
    assert {:ok, %{outcome: :rolled_back}} = Quota.finish(name, token, :rolled_back)
    assert {:ok, retry_token} = Quota.reserve(name, "retryable", :normal_write, :normal, %{wal: 1})
    assert {:ok, %{outcome: :committed}} = Quota.finish(name, retry_token, :committed)
  end

  test "returns a typed disk-capacity result before reservation", %{root: root, name: name} do
    assert {:ok, _pid} =
             Quota.start_link(
               name: name,
               root: root,
               allocation_reader: fn _path, logical -> {:ok, logical} end,
               available_bytes_reader: fn _root -> {:ok, 100} end
             )

    assert {:error, {:quota_disk_capacity, 100, 0, 1_125}} =
             Quota.reserve(name, "disk-full", :normal_write, :normal, %{shared_work: 101})
  end

  test "serializes concurrent reservations without over-admission", %{root: root, name: name} do
    assert {:ok, _pid} = start_quota(name, root)

    results =
      1..12
      |> Task.async_stream(
        fn index ->
          Quota.reserve(name, "concurrent-#{index}", :backup, :normal, %{backups: 100 * @mib})
        end,
        max_concurrency: 12,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    tokens = for {:ok, token} <- results, do: token
    errors = for {:error, reason} <- results, do: reason
    assert length(tokens) == 10
    assert length(errors) == 2
    assert Enum.all?(errors, &match?({:quota_capacity, :backups, _, _, _}, &1))
    assert {:ok, %{reservations: 10, reserved: %{backups: reserved}}} = Quota.status(name)
    assert reserved == 1_000 * @mib

    Enum.each(tokens, fn token -> assert {:ok, _result} = Quota.finish(name, token, :rolled_back) end)
    assert {:ok, %{reservations: 0}} = Quota.status(name)
  end

  test "reconciles completion and quota-owner restart to measured files", %{root: root, name: name} do
    assert {:ok, owner} = start_quota(name, root)
    assert {:ok, token} = Quota.reserve(name, "staged-copy", :restore, :normal, %{shared_work: 1_000})
    write(root, "staging/copy.bin", String.duplicate("x", 500))

    assert {:ok, %{outcome: :committed, measured_budgets: %{shared_work: measured}}} =
             Quota.finish(name, token, :committed)

    assert measured >= 500
    Process.flag(:trap_exit, true)
    Process.exit(owner, :kill)
    assert_receive {:EXIT, ^owner, :killed}

    assert {:ok, _restarted} = eventually_start(name, root)
    assert {:ok, %{reservations: 0, usage: %{shared_work: restarted_measurement}}} = Quota.status(name)
    assert restarted_measurement >= 500
  end

  test "recovers an abandoned reservation with the same operation identity", %{root: root, name: name} do
    assert {:ok, owner} = start_quota(name, root)
    assert {:ok, _token} = Quota.reserve(name, "crash-reservation", :restore, :normal, %{shared_work: 1_000})
    write(root, "staging/recovered.bin", String.duplicate("r", 600))

    Process.flag(:trap_exit, true)
    Process.exit(owner, :kill)
    assert_receive {:EXIT, ^owner, :killed}

    assert {:ok, _restarted} = eventually_start(name, root)

    assert {:ok,
            %{
              operation_id: "crash-reservation",
              operation_kind: :restore,
              outcome: :recovered,
              orphaned: true,
              measured_budgets: %{shared_work: measured}
            }} = Quota.operation(name, "crash-reservation")

    assert measured >= 600
    assert {:ok, %{reservations: 0, reserved_tree_bytes: 0}} = Quota.status(name)
  end

  test "expires an orphaned reservation and records its operation identity", %{root: root, name: name} do
    assert {:ok, _owner} = start_quota(name, root, expiry_ms: 20)
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        {:ok, _token} = Quota.reserve(name, "orphaned", :normal_write, :normal, %{wal: 100})
        send(parent, :reserved)
      end)

    assert_receive :reserved
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}

    assert eventually(fn ->
             match?({:ok, %{outcome: :expired, orphaned: true}}, Quota.operation(name, "orphaned"))
           end)

    assert {:ok, %{reservations: 0, reserved_tree_bytes: 0}} = Quota.status(name)
  end

  test "bounds inventory work", %{root: root} do
    write(root, "one", "1")
    write(root, "two", "2")

    assert {:error, {:quota_inventory_limit, 2, 1}} =
             Quota.inventory(root, inventory_limit: 1, allocation_reader: fn _path, size -> {:ok, size} end)
  end

  test "rejects invalid reservation and inventory inputs", %{root: root, name: name} do
    assert {:ok, _owner} = start_quota(name, root)
    assert {:error, :invalid_quota_outcome} = Quota.finish(name, make_ref(), :unknown)
    assert {:error, :quota_reservation_not_found} = Quota.finish(name, make_ref(), :rolled_back)

    assert {:error, :quota_operation_id_required} =
             Quota.reserve(name, "", :normal_write, :normal, %{})

    assert {:error, :quota_operation_id_required} =
             Quota.reserve(name, String.duplicate("x", 257), :normal_write, :normal, %{})

    assert {:error, :invalid_quota_operation} = Quota.reserve(name, "bad-kind", "write", :normal, %{})
    assert {:error, :invalid_quota_lane} = Quota.reserve(name, "bad-lane", :normal_write, :other, %{})
    assert {:error, :invalid_quota_charges} = Quota.reserve(name, "bad-charges", :normal_write, :normal, [])

    assert {:error, :invalid_quota_charge} =
             Quota.reserve(name, "bad-charge", :normal_write, :normal, %{wal: -1})

    assert {:error, :invalid_temporary_reservation} =
             Quota.reserve(name, "bad-temporary", :normal_write, :normal, %{}, temporary_items: [-1])

    assert {:error, :invalid_quota_inventory_options} = Quota.inventory(root, allocation_reader: :invalid)
    assert {:error, :invalid_quota_inventory_options} = Quota.inventory(root, inventory_limit: 0)
  end

  test "rejects invalid owner options before admission", %{root: root} do
    assert {:error, {:invalid_quota_root, 123}} = Quota.start_link(name: unique(:root), root: 123)

    assert {:error, :invalid_quota_inventory_options} =
             Quota.start_link(name: unique(:allocation), root: root, allocation_reader: :invalid)

    assert {:error, :invalid_quota_available_reader} =
             Quota.start_link(name: unique(:available), root: root, available_bytes_reader: :invalid)

    assert {:error, :invalid_quota_available_bytes} =
             Quota.start_link(
               name: unique(:available_bytes),
               root: root,
               available_bytes_reader: fn _root -> {:ok, -1} end
             )

    assert {:error, :invalid_quota_expiry} =
             Quota.start_link(name: unique(:expiry), root: root, expiry_ms: 0)
  end

  test "fails closed on allocation-reader errors and unsafe journals", %{root: root} do
    file = write(root, "staging/file", "data")

    assert {:error, {:invalid_allocated_size, ^file}} =
             Quota.inventory(root, allocation_reader: fn _path, _logical -> {:ok, :invalid} end)

    assert {:error, {:quota_allocation_unavailable, ^file, :injected}} =
             Quota.inventory(root, allocation_reader: fn _path, _logical -> {:error, :injected} end)

    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "quota-reservations.json"))

    assert {:error, {:unsafe_quota_journal, journal, :directory}} =
             Quota.start_link(name: unique(:unsafe_journal), root: root)

    assert journal == Path.join(root, "quota-reservations.json")
  end

  test "removes an incomplete journal and rejects a corrupt complete journal", %{root: root} do
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    temporary = write(root, "quota-reservations.json.tmp", "incomplete")
    File.chmod!(temporary, 0o600)

    assert {:ok, owner} = start_quota(unique(:temporary_journal), root)
    refute File.exists?(temporary)
    GenServer.stop(owner)

    journal = Path.join(root, "quota-reservations.json")
    File.write!(journal, "{}")
    File.chmod!(journal, 0o600)

    assert {:error, :invalid_quota_journal} =
             Quota.start_link(name: unique(:corrupt_journal), root: root)
  end

  test "rejects invalid durable reservation and result identities", %{root: root} do
    valid_operation = %{
      "operation_id" => "operation",
      "operation_kind" => "normal_write",
      "lane" => "normal",
      "outcome" => "committed",
      "orphaned" => false
    }

    valid_active = %{
      "operation_id" => "active",
      "operation_kind" => "restore",
      "lane" => "normal",
      "requested" => %{"wal" => 1},
      "temporary_bytes" => 0,
      "orphaned" => false
    }

    cases = [
      {"operation-shape", [%{}], [], :invalid_quota_journal_operation},
      {"operation-boolean", [%{valid_operation | "orphaned" => "false"}], [], :invalid_quota_journal_operation},
      {"operation-kind", [%{valid_operation | "operation_kind" => "not-an-existing-atom"}], [],
       :invalid_quota_journal_atom},
      {"operation-lane", [%{valid_operation | "lane" => "normal_write"}], [], :invalid_quota_journal_member},
      {"active-shape", [], [%{}], :invalid_quota_journal_reservation},
      {"active-id", [], [%{valid_active | "operation_id" => ""}], :invalid_quota_journal_operation_id},
      {"active-temporary", [], [%{valid_active | "temporary_bytes" => -1}], :invalid_quota_journal_reservation},
      {"active-usage", [], [%{valid_active | "requested" => %{"wal" => -1}}], :invalid_quota_journal_usage}
    ]

    Enum.each(cases, fn {suffix, operations, active, expected} ->
      case_root = Path.join(root, suffix)
      write_journal(case_root, operations, active)

      assert {:error, ^expected} =
               Quota.start_link(
                 name: unique(:invalid_journal),
                 root: case_root,
                 allocation_reader: fn _path, logical -> {:ok, logical} end,
                 available_bytes_reader: fn _root -> {:ok, 8 * 1_024 * @mib} end
               )
    end)
  end

  defp start_quota(name, root, opts \\ []) do
    defaults = [
      name: name,
      root: root,
      allocation_reader: fn _path, logical -> {:ok, logical} end,
      available_bytes_reader: fn _root -> {:ok, 8 * 1_024 * @mib} end
    ]

    Quota.start_link(Keyword.merge(defaults, opts))
  end

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp write_journal(root, operations, active) do
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    {:ok, bytes} =
      CanonicalJSON.encode(%{
        "schema" => "jido.storage-quota",
        "schema_version" => 1,
        "active" => active,
        "operations" => operations
      })

    path = write(root, "quota-reservations.json", bytes)
    File.chmod!(path, 0o600)
  end

  defp unique(prefix), do: :"jido-quota-#{prefix}-#{System.unique_integer([:positive])}"

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp eventually_start(name, root, attempts \\ 50)

  defp eventually_start(name, root, attempts) when attempts > 0 do
    case start_quota(name, root) do
      {:ok, _pid} = ok ->
        ok

      {:error, {:already_started, _pid}} ->
        Process.sleep(10)
        eventually_start(name, root, attempts - 1)

      {:error, _reason} = error ->
        error
    end
  end

  defp eventually_start(_name, _root, 0), do: {:error, :quota_restart_timeout}
end
