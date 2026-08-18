defmodule Jido.Console.StorageTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Session.Durable.Record
  alias Jido.Console.Storage
  alias Jido.Console.Storage.{Admission, HomeLock, Maintenance, Quota}

  @digest "sha256:" <> String.duplicate("a", 64)

  defmodule BlockedWriter do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(:ok), do: {:ok, %{}}

    def handle_call(_message, _from, state) do
      Process.sleep(100)
      {:reply, {:error, :late}, state}
    end
  end

  defmodule FailingWriter do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(:ok), do: {:ok, %{}}
    def handle_call(_message, _from, state), do: {:reply, {:error, :injected_writer_failure}, state}
  end

  defmodule ExitingWriter do
    use GenServer

    def start(name, reason), do: GenServer.start(__MODULE__, reason, name: name)
    def init(reason), do: {:ok, reason}
    def handle_call(_message, _from, reason), do: {:stop, reason, reason}
  end

  defmodule CheckpointExitingWriter do
    use GenServer

    def start(name), do: GenServer.start(__MODULE__, :ok, name: name)
    def init(:ok), do: {:ok, %{}}

    def handle_call({:append, _operation_id, _encoded}, _from, state),
      do: {:reply, {:ok, %{record_id: "record-0", sequence: 0}}, state}

    def handle_call(:checkpoint, _from, state), do: {:stop, :shutdown, state}
  end

  defmodule KillingAdmission do
    use GenServer

    def start_link(name, writer), do: GenServer.start_link(__MODULE__, writer, name: name)
    def init(writer), do: {:ok, writer}

    def handle_call({:reserve, _lane, _payload, _opts}, _from, writer) do
      Process.exit(writer, :kill)
      {:reply, {:ok, make_ref()}, writer}
    end

    def handle_cast({:release, _token}, writer), do: {:noreply, writer}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "jido-storage-#{System.unique_integer([:positive])}")

    names = [
      name: unique(:supervisor),
      lock: unique(:lock),
      maintenance: unique(:maintenance),
      quota: unique(:quota),
      admission: unique(:admission),
      writer: unique(:writer),
      jido_home: root
    ]

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, names: names}
  end

  test "owns lock, maintenance, admission, and writer in rest-for-one order", %{names: names} do
    assert {:ok, supervisor} = Jido.Console.Storage.Supervisor.start_link(names)

    assert [
             {Jido.Console.Session.Store.SQLite, writer, :worker, _},
             {Admission, admission, :worker, _},
             {Quota, quota, :worker, _},
             {Maintenance, maintenance, :worker, _},
             {HomeLock, lock, :worker, _}
           ] = Supervisor.which_children(supervisor)

    assert writer == Process.whereis(names[:writer])
    assert admission == Process.whereis(names[:admission])
    assert quota == Process.whereis(names[:quota])
    assert maintenance == Process.whereis(names[:maintenance])
    assert lock == Process.whereis(names[:lock])

    writer_ref = Process.monitor(writer)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^writer_ref, :process, ^writer, :killed}
    assert eventually(fn -> is_pid(Process.whereis(names[:writer])) end)
    assert Process.whereis(names[:admission]) == admission

    second_writer = Process.whereis(names[:writer])
    lock_ref = Process.monitor(lock)
    Process.exit(lock, :kill)
    assert_receive {:DOWN, ^lock_ref, :process, ^lock, :killed}

    assert eventually(fn ->
             Process.whereis(names[:writer]) not in [nil, second_writer] and
               Process.whereis(names[:admission]) not in [nil, admission]
           end)
  end

  test "denies a second writable owner and releases after owner death", %{root: root} do
    first = unique(:first_lock)
    second = unique(:second_lock)
    third = unique(:third_lock)

    assert {:ok, owner} = HomeLock.start_link(name: first, jido_home: root)
    Process.flag(:trap_exit, true)
    assert {:error, {:home_locked, path}} = HomeLock.start_link(name: second, jido_home: root)
    assert path == Path.join(root, "state/sessions/v1/home-lock.sqlite3")

    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
    assert {:ok, replacement} = eventually_start_lock(third, root)
    GenServer.stop(replacement)
  end

  test "enforces exact slots, payload lanes, and WAL states", %{names: names} do
    assert {:ok, admission} = Admission.start_link(name: names[:admission])

    assert Admission.limits() == %{
             control_large_bytes: 142_606_336,
             control_slots: 16,
             normal_large_bytes: 142_606_336,
             normal_slots: 112,
             small_payload_bytes: 16_777_216,
             total_logical_payload_bytes: 301_989_888,
             transactions: 1,
             wal_hard_bytes: 402_653_184,
             wal_soft_bytes: 67_108_864
           }

    normal = Enum.map(1..112, fn _ -> reserve!(admission, :normal, 0) end)
    assert {:error, {:storage_busy, :normal_slots}} = Admission.reserve(admission, :normal, 0)

    control = Enum.map(1..16, fn _ -> reserve!(admission, :control, 0) end)
    assert {:error, {:storage_busy, :control_slots}} = Admission.reserve(admission, :control, 0)
    Enum.each(normal ++ control, &Admission.release(admission, &1))

    assert eventually(fn ->
             match?({:ok, %{normal_operations: 0, control_operations: 0}}, Admission.status(admission))
           end)

    small = reserve!(admission, :normal, 16_777_216)
    normal_large = reserve!(admission, :normal, 142_606_336)
    control_large = reserve!(admission, :control, 142_606_336)
    assert {:error, {:storage_busy, {:normal, :large_lane}}} = Admission.reserve(admission, :normal, 1)

    assert {:error, {:storage_capacity, :control, 142_606_337, 142_606_336}} =
             Admission.reserve(admission, :control, 142_606_337)

    assert {:ok, %{small_payload_bytes: 16_777_216, normal_large?: true, control_large?: true}} =
             Admission.status(admission)

    Enum.each([small, normal_large, control_large], &Admission.release(admission, &1))
    assert eventually(fn -> match?({:ok, %{small_payload_bytes: 0}}, Admission.status(admission)) end)

    assert :ok = Admission.wal(admission, 67_108_864, :busy)

    assert {:error, {:storage_busy, :checkpoint_required}} =
             Admission.reserve(admission, :normal, 1, page_bytes: 1)

    assert {:ok, control_token} = Admission.reserve(admission, :control, 1, page_bytes: 1)
    Admission.release(admission, control_token)
    assert :ok = Admission.wal(admission, 402_653_184, :blocked)

    assert {:error, {:storage_busy, :wal_blocked}} =
             Admission.reserve(admission, :control, 1, page_bytes: 1)

    assert {:error, :invalid_storage_reservation} = Admission.reserve(admission, :invalid, -1)
    Admission.release(admission, make_ref())

    assert :ok = Admission.wal(admission, 402_653_184, :ready)

    assert {:error, {:storage_busy, :wal_hard_limit}} =
             Admission.reserve(admission, :control, 1, page_bytes: 1)
  end

  test "releases a reservation when its caller dies", %{names: names} do
    assert {:ok, admission} = Admission.start_link(name: names[:admission])
    parent = self()

    caller =
      spawn(fn ->
        {:ok, _token} = Admission.reserve(admission, :normal, 1_024)
        send(parent, :reserved)
        Process.sleep(:infinity)
      end)

    assert_receive :reserved
    assert {:ok, %{normal_operations: 1, small_payload_bytes: 1_024}} = Admission.status(admission)
    Process.exit(caller, :kill)

    assert eventually(fn ->
             match?(
               {:ok, %{normal_operations: 0, small_payload_bytes: 0}},
               Admission.status(admission)
             )
           end)
  end

  test "writes, syncs, completes, and reconciles one bounded maintenance manifest", %{root: root, names: names} do
    assert {:ok, owner} = Maintenance.start_link(name: names[:maintenance], jido_home: root)

    assert {:ok, %{"operation_id" => "backup-one", "state" => "prepared"} = manifest} =
             Maintenance.prepare(names[:maintenance], "backup-one", "backup", %{"target" => "safe"})

    assert {:ok, ^manifest} = Maintenance.current(names[:maintenance])
    path = Path.join(root, "state/sessions/v1/maintenance.json")
    assert {:ok, %{mode: mode, type: :regular}} = File.lstat(path)
    assert Bitwise.band(mode, 0o077) == 0

    assert {:error, :maintenance_operation_active} =
             Maintenance.prepare(names[:maintenance], "backup-two", "backup")

    GenServer.stop(owner)
    restarted = unique(:restarted_maintenance)
    assert {:ok, _pid} = Maintenance.start_link(name: restarted, jido_home: root)
    assert {:ok, nil} = Maintenance.current(restarted)
    refute File.exists?(path)

    assert {:ok, _manifest} = Maintenance.prepare(restarted, "archive-one", "archive")
    assert :ok = Maintenance.complete(restarted, "archive-one")

    assert {:error, {:maintenance_operation_not_found, "archive-one"}} =
             Maintenance.complete(restarted, "archive-one")
  end

  test "rejects unsafe and oversized maintenance state", %{root: root} do
    path = Path.join(root, "state/sessions/v1/maintenance.json")
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(root, 0o700)
    File.chmod!(Path.join(root, "state"), 0o700)
    File.chmod!(Path.join(root, "state/sessions"), 0o700)
    File.chmod!(Path.dirname(path), 0o700)
    File.write!(path, String.duplicate("x", 65_537))
    File.chmod!(path, 0o600)
    Process.flag(:trap_exit, true)

    assert {:error, {:maintenance_manifest_too_large, 65_537, 65_536}} =
             Maintenance.start_link(name: unique(:oversized), jido_home: root)

    File.rm!(path)
    File.ln_s!(Path.join(root, "outside"), path)

    assert {:error, {:unsafe_maintenance_manifest, ^path, :symlink}} =
             Maintenance.start_link(name: unique(:unsafe), jido_home: root)
  end

  test "rejects an oversized new manifest and invalid recovered content", %{root: root} do
    owner = unique(:bounded_maintenance)
    assert {:ok, pid} = Maintenance.start_link(name: owner, jido_home: root)

    assert {:error, {:maintenance_manifest_too_large, size, 65_536}} =
             Maintenance.prepare(owner, "large", "backup", %{
               "payload" => String.duplicate("x", 65_536)
             })

    assert size > 65_536
    GenServer.stop(pid)

    path = Path.join(root, "state/sessions/v1/maintenance.json")
    File.write!(path, "{}")
    File.chmod!(path, 0o600)
    Process.flag(:trap_exit, true)

    assert {:error, :invalid_maintenance_manifest} =
             Maintenance.start_link(name: unique(:invalid_manifest), jido_home: root)
  end

  test "recovers a stale temporary manifest and tolerates an already removed final manifest", %{
    root: root
  } do
    owner = unique(:stale_temp_maintenance)
    assert {:ok, _pid} = Maintenance.start_link(name: owner, jido_home: root)
    path = Path.join(root, "state/sessions/v1/maintenance.json")
    File.write!(path <> ".tmp", "stale")

    assert {:error, :invalid_maintenance_operation} = Maintenance.prepare(owner, "", "", %{})
    assert {:ok, _manifest} = Maintenance.prepare(owner, "cleanup", "repair")
    refute File.exists?(path <> ".tmp")
    File.rm!(path)
    assert :ok = Maintenance.complete(owner, "cleanup")
  end

  test "rejects noncanonical recovered maintenance JSON", %{root: root} do
    path = Path.join(root, "state/sessions/v1/maintenance.json")
    File.mkdir_p!(Path.dirname(path))

    for directory <- [root, Path.join(root, "state"), Path.join(root, "state/sessions"), Path.dirname(path)] do
      File.chmod!(directory, 0o700)
    end

    File.write!(path, ~s({"z":1,"a":2}))
    File.chmod!(path, 0o600)
    Process.flag(:trap_exit, true)

    assert {:error, :noncanonical_json} =
             Maintenance.start_link(name: unique(:noncanonical_manifest), jido_home: root)
  end

  test "keeps maintenance active when manifest removal fails", %{root: root} do
    owner = unique(:remove_failure_maintenance)
    assert {:ok, _pid} = Maintenance.start_link(name: owner, jido_home: root)
    assert {:ok, manifest} = Maintenance.prepare(owner, "remove-failure", "repair")

    path = Path.join(root, "state/sessions/v1/maintenance.json")
    File.rm!(path)
    File.mkdir!(path)

    assert {:error, {:maintenance_manifest_remove_failed, ^path, _reason}} =
             Maintenance.complete(owner, "remove-failure")

    assert {:ok, ^manifest} = Maintenance.current(owner)
  end

  test "rejects a symbolic-link home lock", %{root: root} do
    path = Path.join(root, "state/sessions/v1/home-lock.sqlite3")
    File.mkdir_p!(Path.dirname(path))

    for directory <- [root, Path.join(root, "state"), Path.join(root, "state/sessions"), Path.dirname(path)] do
      File.chmod!(directory, 0o700)
    end

    File.ln_s!(Path.join(root, "outside"), path)
    Process.flag(:trap_exit, true)

    assert {:error, {:unsafe_home_lock, ^path, :symlink}} =
             HomeLock.start_link(name: unique(:unsafe_lock), jido_home: root)
  end

  test "rejects unsafe permissions and corrupt home-lock databases", %{root: root} do
    path = Path.join(root, "state/sessions/v1/home-lock.sqlite3")
    File.mkdir_p!(Path.dirname(path))

    for directory <- [root, Path.join(root, "state"), Path.join(root, "state/sessions"), Path.dirname(path)] do
      File.chmod!(directory, 0o700)
    end

    File.write!(path, "not a sqlite database")
    File.chmod!(path, 0o644)
    Process.flag(:trap_exit, true)

    assert {:error, {:unsafe_permissions, ^path, _mode}} =
             HomeLock.start_link(name: unique(:wide_lock), jido_home: root)

    File.chmod!(path, 0o600)

    assert {:error, {:home_lock_failed, ^path, _reason}} =
             HomeLock.start_link(name: unique(:corrupt_lock), jido_home: root)
  end

  test "public writes reserve before the private writer mailbox and remain resolvable", %{names: names} do
    assert {:ok, supervisor} = Jido.Console.Storage.Supervisor.start_link(names)

    opts = [
      quota: names[:quota],
      admission: names[:admission],
      writer: names[:writer],
      operation_id: "append-zero"
    ]

    assert {:ok, %{record_id: "record-0", sequence: 0}} = Storage.append(record(), opts)

    assert {:ok, %{operation_id: "append-zero", target_id: "record-0"}} =
             Storage.receipt("append-zero", opts)

    assert {:ok, [%{record: %{"record_id" => "record-0"}}]} =
             Storage.range("storage-fixture", opts)

    assert {:ok, %{integrity: :ok}} = Storage.inspect_store(opts)

    assert {:ok,
            %{
              bytes: wal_bytes,
              checkpoint: :ready,
              soft_limit_bytes: 67_108_864,
              hard_limit_bytes: 402_653_184
            }} = Jido.Console.Session.Store.SQLite.checkpoint(names[:writer])

    assert wal_bytes < 67_108_864

    assert {:ok,
            %{
              admission: %{normal_operations: 0},
              quota: %{reservations: 0},
              writer: :available
            }} = Storage.status(opts)

    directory = Path.join(names[:jido_home], "state/sessions/v1")

    for name <- [
          "console.sqlite3",
          "console.sqlite3-wal",
          "console.sqlite3-shm",
          "home-lock.sqlite3",
          "home-lock.sqlite3-journal"
        ] do
      path = Path.join(directory, name)

      if File.exists?(path) do
        assert {:ok, %{type: :regular, mode: mode}} = File.lstat(path)
        assert Bitwise.band(mode, 0o077) == 0
      end
    end

    assert {:error, :storage_writer_must_be_stopped} =
             Maintenance.prepare(names[:maintenance], "backup-direct", "backup")

    assert {:error, :invalid_maintenance_operation} =
             Jido.Console.Storage.Supervisor.begin_maintenance(
               supervisor,
               "",
               "",
               %{},
               maintenance: names[:maintenance]
             )

    assert eventually(fn -> is_pid(Process.whereis(names[:writer])) end)

    assert {:ok, %{"operation_id" => "backup-owned"}} =
             Jido.Console.Storage.Supervisor.begin_maintenance(
               supervisor,
               "backup-owned",
               "backup",
               %{"target" => "fixture"},
               maintenance: names[:maintenance]
             )

    refute Process.whereis(names[:writer])
    assert {:error, :storage_unavailable} = Storage.receipt("append-zero", opts)

    assert {:error, {:maintenance_operation_not_found, "wrong-operation"}} =
             Jido.Console.Storage.Supervisor.complete_maintenance(supervisor, "wrong-operation",
               maintenance: names[:maintenance]
             )

    assert :ok =
             Jido.Console.Storage.Supervisor.complete_maintenance(supervisor, "backup-owned",
               maintenance: names[:maintenance]
             )

    assert eventually(fn -> is_pid(Process.whereis(names[:writer])) end)
    assert {:ok, %{operation_id: "append-zero"}} = Storage.receipt("append-zero", opts)
  end

  test "returns typed unavailable and timeout-unknown results without leaking admission", %{names: names} do
    assert {:ok, _quota} = Quota.start_link(name: names[:quota], jido_home: names[:jido_home])
    assert {:ok, _admission} = Admission.start_link(name: names[:admission])

    assert {:error, :operation_id_required} =
             Storage.append(record(), admission: names[:admission], writer: names[:writer])

    assert {:error, :storage_unavailable} =
             Storage.append(record(),
               admission: names[:admission],
               quota: names[:quota],
               writer: names[:writer],
               operation_id: "unavailable"
             )

    assert {:ok, %{reservations: 0}} = Quota.status(names[:quota])

    missing_admission = unique(:missing_admission)

    assert {:error, :storage_unavailable} =
             Storage.append(record(),
               admission: missing_admission,
               quota: names[:quota],
               writer: names[:writer],
               operation_id: "admission-unavailable"
             )

    assert {:ok, %{reservations: 0}} = Quota.status(names[:quota])

    assert {:error, :storage_unavailable} =
             Storage.status(quota: names[:quota], admission: names[:admission], writer: names[:writer])

    assert {:error, :storage_unavailable} = Storage.range("missing", writer: names[:writer])
    assert {:error, :storage_unavailable} = Storage.inspect_store(writer: names[:writer])

    assert {:ok, _writer} = BlockedWriter.start_link(names[:writer])

    assert {:error, {:timeout_unknown, "slow-operation"}} =
             Storage.append(record(),
               admission: names[:admission],
               quota: names[:quota],
               writer: names[:writer],
               operation_id: "slow-operation",
               deadline: 10
             )

    assert {:ok, %{reservations: 1, reserved: %{active_database: database, wal: wal}}} =
             Quota.status(names[:quota])

    assert database > 0
    assert wal > 0

    assert {:error, :storage_reader_timeout} =
             Storage.range("storage-fixture",
               admission: names[:admission],
               writer: names[:writer],
               deadline: 10
             )

    assert {:error, :storage_reader_timeout} =
             Storage.inspect_store(writer: names[:writer], deadline: 10)

    assert {:error, :storage_unavailable} =
             Storage.receipt("slow-operation", writer: names[:writer], deadline: 10)

    assert eventually(fn -> match?({:ok, %{normal_operations: 0}}, Admission.status(names[:admission])) end)
  end

  test "handles writer failure and writer death after admission", %{names: names} do
    assert {:ok, _quota} = Quota.start_link(name: names[:quota], jido_home: names[:jido_home])
    assert {:ok, admission} = Admission.start_link(name: names[:admission])
    assert {:ok, failing} = FailingWriter.start_link(names[:writer])

    assert {:error, :injected_writer_failure} =
             Storage.append(record(),
               admission: admission,
               quota: names[:quota],
               writer: names[:writer],
               operation_id: "failed-write"
             )

    GenServer.stop(failing)
    writer = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(writer, names[:writer])
    GenServer.stop(admission)
    assert {:ok, _killer} = KillingAdmission.start_link(names[:admission], writer)

    assert {:error, :storage_unavailable} =
             Storage.append(record(),
               admission: names[:admission],
               quota: names[:quota],
               writer: names[:writer],
               operation_id: "writer-died"
             )
  end

  test "maps writer exits to typed public results", %{names: names} do
    assert {:ok, _quota} = Quota.start_link(name: names[:quota], jido_home: names[:jido_home])
    assert {:ok, admission} = Admission.start_link(name: names[:admission])

    for operation <- [:append, :range, :inspect, :status] do
      reason = if operation == :append, do: :normal, else: :shutdown
      assert {:ok, writer} = ExitingWriter.start(names[:writer], reason)

      result =
        case operation do
          :append ->
            Storage.append(record(),
              admission: admission,
              quota: names[:quota],
              writer: names[:writer],
              operation_id: "exit-write"
            )

          :range ->
            Storage.range("storage-fixture", writer: names[:writer])

          :inspect ->
            Storage.inspect_store(writer: names[:writer])

          :status ->
            Storage.status(quota: names[:quota], admission: admission, writer: names[:writer])
        end

      assert {:error, :storage_unavailable} = result
      assert eventually(fn -> Process.whereis(names[:writer]) == nil end)
      refute Process.alive?(writer)
    end

    assert {:ok, writer} = CheckpointExitingWriter.start(names[:writer])

    assert {:ok, %{record_id: "record-0", sequence: 0}} =
             Storage.append(record(),
               admission: admission,
               quota: names[:quota],
               writer: names[:writer],
               operation_id: "checkpoint-exit"
             )

    assert eventually(fn -> not Process.alive?(writer) end)
    assert {:ok, %{normal_operations: 0}} = Admission.status(admission)
  end

  test "the supervised writer fails closed on corrupt durable rows", %{root: root, names: names} do
    alias Exqlite.Sqlite3
    alias Jido.Console.Session.Store.SQLite

    assert {:ok, writer} = SQLite.start_link(jido_home: root)
    assert {:ok, _result} = SQLite.append(writer, record(), operation_id: "corrupt-before-start")
    GenServer.stop(writer)

    path = Path.join(root, "state/sessions/v1/console.sqlite3")
    assert {:ok, conn} = Sqlite3.open(path)
    assert :ok = Sqlite3.execute(conn, "UPDATE records SET digest='sha256:bad'")
    assert :ok = Sqlite3.close(conn)
    Process.flag(:trap_exit, true)

    assert {:error, reason} = Jido.Console.Storage.Supervisor.start_link(names)
    assert inspect(reason) =~ "record_integrity_failed"
  end

  test "the application orders storage before sessions" do
    application = Process.whereis(Jido.Console.Supervisor)

    assert [
             {Jido.Console.Session.Supervisor, _, :supervisor, _},
             {Jido.Console.Storage.Supervisor, _, :supervisor, _},
             {Jido.Console.Process.Supervisor, _, :worker, _}
           ] = Supervisor.which_children(application)
  end

  defp record do
    Record.new(
      "input_receipt",
      %{
        "operation_id" => "operation-0",
        "idempotency_key" => "idempotency-0",
        "payload_digest" => @digest,
        "input_id" => "input-0",
        "admission_state" => "accepted"
      },
      record_id: "record-0",
      scope_id: "storage-fixture",
      generation: 1,
      sequence: 0,
      prior_record_digest: "genesis"
    )
  end

  defp reserve!(server, lane, payload) do
    {:ok, token} = Admission.reserve(server, lane, payload)
    token
  end

  defp unique(prefix), do: :"jido-storage-#{prefix}-#{System.unique_integer([:positive])}"

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp eventually_start_lock(name, root, attempts \\ 50)

  defp eventually_start_lock(name, root, attempts) when attempts > 0 do
    case HomeLock.start_link(name: name, jido_home: root) do
      {:ok, _pid} = ok ->
        ok

      {:error, {:home_locked, _path}} ->
        Process.sleep(10)
        eventually_start_lock(name, root, attempts - 1)

      {:error, _reason} = error ->
        error
    end
  end

  defp eventually_start_lock(_name, _root, 0), do: {:error, :home_lock_timeout}
end
