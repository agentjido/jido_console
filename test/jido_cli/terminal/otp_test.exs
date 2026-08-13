defmodule Jido.Cli.Terminal.OTPTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Terminal.OTP
  alias Jido.Cli.Terminal.OTP.Handle
  alias Jido.Cli.Terminal.OTP.Reader

  test "opens, reads, writes, resizes, and closes through injected effects" do
    {:ok, sizes} = Agent.start_link(fn -> {:ok, {20, 6}} end)

    assert {:ok, %Handle{} = handle, ref, {20, 6}} =
             OTP.open(self(), adapter_opts(self(), sizes))

    assert_receive {:terminal_write, enter}
    assert enter =~ "\e[?1049h"

    assert :ok = OTP.write(handle, "frame")
    assert_receive {:terminal_write, "frame"}
    assert {:ok, {20, 6}} = OTP.size(handle)

    send(handle.pid, {:terminal_bytes, "a"})
    assert_receive {:jido_terminal, ^ref, {:text, "a"}}

    send(handle.pid, {:terminal_bytes, "\e"})
    assert_receive {:jido_terminal, ^ref, {:key, :escape}}, 100

    send(handle.pid, {:flush_escape, make_ref()})
    send(handle.pid, :terminal_eof)
    send(handle.pid, {:terminal_error, :closed})
    send(handle.pid, :unknown_message)
    assert_receive {:jido_terminal, ^ref, :eof}
    assert_receive {:jido_terminal, ^ref, :eof}

    Agent.update(sizes, fn _size -> {:ok, {30, 10}} end)
    send(handle.pid, :check_size)
    assert_receive {:jido_terminal, ^ref, {:resize, 30, 10}}

    send(handle.pid, :check_size)
    refute_receive {:jido_terminal, ^ref, {:resize, _, _}}, 20

    assert :ok = OTP.close(handle)
    assert_receive {:terminal_write, leave}
    assert leave =~ "\e[?1049l"
    assert {:error, :closed} = OTP.write(handle, "late")
    assert {:error, :closed} = OTP.size(handle)
    assert :ok = OTP.close(handle)
  end

  test "reports a size failure without replacing the last size" do
    {:ok, sizes} = Agent.start_link(fn -> {:ok, {20, 6}} end)
    assert {:ok, handle, _ref, {20, 6}} = OTP.open(self(), adapter_opts(self(), sizes))
    assert_receive {:terminal_write, _enter}

    Agent.update(sizes, fn _size -> {:error, :unavailable} end)
    assert {:error, :not_a_terminal} = OTP.size(handle)
    assert :ok = OTP.close(handle)
    assert_receive {:terminal_write, _leave}
  end

  test "closes when its owner exits" do
    test_pid = self()
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    {:ok, sizes} = Agent.start_link(fn -> {:ok, {20, 6}} end)
    opts = adapter_opts(test_pid, sizes)

    assert {:ok, %Handle{pid: server}, _ref, _size} = OTP.open(owner, opts)
    assert_receive {:terminal_write, _enter}
    monitor = Process.monitor(server)
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^server, :normal}
    assert_receive {:terminal_write, _leave}
  end

  test "validates OTP, raw mode, size, and initial output" do
    {:ok, sizes} = Agent.start_link(fn -> {:ok, {20, 6}} end)
    base = adapter_opts(self(), sizes)

    assert {:error, {:unsupported_otp, "27"}} =
             OTP.open(self(), Keyword.put(base, :otp_release, fn -> "27" end))

    assert {:error, :interactive_shell_already_started} =
             OTP.open(self(), Keyword.put(base, :start_raw, fn -> {:error, :already_started} end))

    assert {:error, {:raw_terminal_failed, :denied}} =
             OTP.open(self(), Keyword.put(base, :start_raw, fn -> {:error, :denied} end))

    assert {:error, :not_a_terminal} =
             OTP.open(self(), Keyword.put(base, :size, fn -> {:ok, {0, 0}} end))

    assert {:error, :not_a_terminal} =
             OTP.open(self(), Keyword.put(base, :size, fn -> raise "size failed" end))

    assert {:error, :write_failed} =
             OTP.open(self(), Keyword.put(base, :write, fn _output -> {:error, :write_failed} end))

    assert {:error, %RuntimeError{message: "write failed"}} =
             OTP.open(self(), Keyword.put(base, :write, fn _output -> raise "write failed" end))
  end

  test "reader forwards data, errors, and end of file" do
    {:ok, values} = Agent.start_link(fn -> [:ignored, ~c"a", "x", {:error, :read_failed}] end)
    read = queue_reader(values)
    assert {:ok, reader} = Reader.start_link(self(), read)
    monitor = Process.monitor(reader)
    assert_receive {:terminal_bytes, "a"}
    assert_receive {:terminal_bytes, "x"}
    assert_receive {:terminal_error, :read_failed}
    assert_receive {:DOWN, ^monitor, :process, ^reader, :normal}

    assert {:ok, eof_reader} = Reader.start_link(self(), fn -> :eof end)
    eof_monitor = Process.monitor(eof_reader)
    assert_receive :terminal_eof
    assert_receive {:DOWN, ^eof_monitor, :process, ^eof_reader, :normal}
  end

  defp adapter_opts(test_pid, sizes) do
    [
      escape_timeout_ms: 1,
      read: fn -> receive do: (_message -> :eof) end,
      resize_interval_ms: 60_000,
      size: fn -> Agent.get(sizes, & &1) end,
      start_raw: fn -> :ok end,
      write: fn output ->
        send(test_pid, {:terminal_write, IO.iodata_to_binary(output)})
        :ok
      end
    ]
  end

  defp queue_reader(values) do
    fn ->
      Agent.get_and_update(values, fn
        [value | rest] -> {value, rest}
        [] -> {:eof, []}
      end)
    end
  end
end
