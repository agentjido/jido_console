defmodule Jido.Console.AgentSource.FileTest do
  use ExUnit.Case, async: false

  alias Jido.Console.AgentSource
  alias Jido.Console.Digest

  @fixture Path.expand("../../fixtures/agents/valid.json", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "jido-agent-file-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "rejects missing, directory, FIFO, and direct symbolic-link sources", %{root: root} do
    assert {:error, :agent_source_missing} =
             AgentSource.resolve(Path.join(root, "missing.json"), startup_cwd: root)

    directory = Path.join(root, "directory.json")
    File.mkdir!(directory)
    assert {:error, :agent_source_not_regular} = AgentSource.resolve(directory, startup_cwd: root)

    fifo = Path.join(root, "fifo.json")
    assert {_, 0} = System.cmd("mkfifo", [fifo])
    assert {:error, :agent_source_not_regular} = AgentSource.resolve(fifo, startup_cwd: root)

    link = Path.join(root, "link.json")
    File.ln_s!(@fixture, link)
    assert {:error, :agent_source_symlink} = AgentSource.resolve(link, startup_cwd: root)
  end

  test "accepts exactly 1,000,000 bytes and rejects one byte more before import", %{root: root} do
    prefix = ~S({"agent":{"id":"size_agent","model":"openai:gpt-4.1-mini","instructions":")
    suffix = ~S("}})
    exact = prefix <> String.duplicate("x", 1_000_000 - byte_size(prefix) - byte_size(suffix)) <> suffix
    exact_path = Path.join(root, "exact.json")
    File.write!(exact_path, exact)
    assert byte_size(exact) == 1_000_000

    test_pid = self()
    before_import = fn bytes, _format -> send(test_pid, {:imported_bytes, byte_size(bytes)}) end

    assert {:ok, record} =
             AgentSource.resolve(exact_path, startup_cwd: root, before_import: before_import)

    assert record.byte_size == 1_000_000
    assert record.digest == Digest.portable(exact)
    assert_receive {:imported_bytes, 1_000_000}

    over_path = Path.join(root, "over.json")
    File.write!(over_path, exact <> " ")

    assert {:error, :agent_source_too_large} =
             AgentSource.resolve(over_path, startup_cwd: root, before_import: before_import)

    refute_receive {:imported_bytes, 1_000_001}
  end

  test "rejects invalid UTF-8 and hashes the exact retained bytes", %{root: root} do
    invalid = Path.join(root, "invalid.yaml")
    File.write!(invalid, <<255>>)
    assert {:error, :agent_source_invalid_utf8} = AgentSource.resolve(invalid, startup_cwd: root)

    path = Path.join(root, "bytes.json")
    bytes = File.read!(@fixture) <> "\n"
    File.write!(path, bytes)
    test_pid = self()

    assert {:ok, record} =
             AgentSource.resolve(path,
               startup_cwd: root,
               before_import: fn imported, format -> send(test_pid, {:imported, imported, format}) end
             )

    assert_receive {:imported, ^bytes, :json}
    assert record.digest == Digest.portable(bytes)
    assert record.byte_size == byte_size(bytes)
  end

  test "detects identity replacement before and after the retained read", %{root: root} do
    for hook_name <- [:after_lstat, :after_open, :after_read] do
      path = Path.join(root, "swap-#{hook_name}.json")
      File.cp!(@fixture, path)

      hook = fn canonical_path, _value ->
        replacement = canonical_path <> ".replacement"
        File.write!(replacement, File.read!(@fixture) <> " ")
        File.rename!(replacement, canonical_path)
      end

      assert {:error, :agent_source_changed} =
               AgentSource.resolve(path,
                 startup_cwd: root,
                 file_hooks: [{hook_name, hook}]
               )
    end
  end

  test "rejects a FIFO swap before the final open check", %{root: root} do
    path = Path.join(root, "stalled.json")
    File.cp!(@fixture, path)
    test_pid = self()

    swap_to_fifo = fn canonical_path, _stat ->
      File.rm!(canonical_path)
      assert {_, 0} = System.cmd("mkfifo", [canonical_path])
      send(test_pid, {:worker, self()})
    end

    assert {:error, :agent_source_not_regular} =
             AgentSource.resolve(path,
               startup_cwd: root,
               deadline_ms: 50,
               file_hooks: [after_lstat: swap_to_fifo],
               before_import: fn _bytes, _format -> send(test_pid, :import_reached) end
             )

    assert_receive {:worker, worker}
    refute Process.alive?(worker)
    refute_received :import_reached
  end

  test "bounds a stall immediately before the retained read", %{root: root} do
    path = Path.join(root, "stalled-read.json")
    File.cp!(@fixture, path)
    test_pid = self()

    before_read = fn _canonical_path, _device ->
      send(test_pid, {:read_worker, self()})
      Process.sleep(:infinity)
    end

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :agent_source_deadline_exceeded} =
             AgentSource.resolve(path,
               startup_cwd: root,
               deadline_ms: 100,
               file_hooks: [before_read: before_read],
               before_import: fn _bytes, _format -> send(test_pid, :import_reached) end
             )

    assert System.monotonic_time(:millisecond) - started_at < 1_000
    assert_receive {:read_worker, worker}
    refute Process.alive?(worker)
    refute_received :import_reached

    assert {:ok, _record} = AgentSource.resolve(path, startup_cwd: root)
  end

  test "bounds a stalled import and closes the monitored file handle", %{root: root} do
    path = Path.join(root, "stalled-import.json")
    File.cp!(@fixture, path)
    test_pid = self()

    after_open = fn _path, device -> send(test_pid, {:open_device, device}) end

    before_import = fn _bytes, _format ->
      send(test_pid, {:import_worker, self()})
      Process.sleep(:infinity)
    end

    task =
      Task.async(fn ->
        AgentSource.resolve(path,
          startup_cwd: root,
          deadline_ms: 100,
          file_hooks: [after_open: after_open],
          before_import: before_import
        )
      end)

    assert_receive {:open_device, device}
    device_ref = Process.monitor(device)
    assert_receive {:import_worker, worker}
    assert {:error, :agent_source_deadline_exceeded} = Task.await(task)
    refute Process.alive?(worker)
    assert_receive {:DOWN, ^device_ref, :process, ^device, _reason}
  end

  test "enforces a worker heap ceiling", %{root: root} do
    path = Path.join(root, "heap.json")
    File.cp!(@fixture, path)

    consume_heap = fn _path, _stat ->
      Process.put(:agent_source_heap_pressure, Enum.to_list(1..100_000))
    end

    assert {:error, :agent_source_heap_limit_exceeded} =
             AgentSource.resolve(path,
               startup_cwd: root,
               worker_max_heap_bytes: 200_000,
               file_hooks: [after_lstat: consume_heap]
             )
  end
end
