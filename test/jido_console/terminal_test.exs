defmodule Jido.Console.TerminalTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Terminal
  alias Jido.Console.Terminal.Frame

  defmodule FakeAdapter do
    @behaviour Jido.Console.Terminal.Adapter

    @impl true
    def open(owner, opts) do
      ref = make_ref()
      test_pid = Keyword.fetch!(opts, :test_pid)
      handle = %{owner: owner, ref: ref, test_pid: test_pid, size: {20, 6}}
      send(test_pid, {:opened, owner, ref})
      {:ok, handle, ref, handle.size}
    end

    @impl true
    def write(handle, output) do
      send(handle.test_pid, {:write, IO.iodata_to_binary(output)})
      :ok
    end

    @impl true
    def size(handle), do: {:ok, handle.size}

    @impl true
    def close(handle) do
      send(handle.test_pid, :closed)
      :ok
    end
  end

  defmodule RaisingAdapter do
    @behaviour Jido.Console.Terminal.Adapter

    @impl true
    def open(owner, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      ref = make_ref()
      {:ok, %{owner: owner, test_pid: test_pid}, ref, {20, 6}}
    end

    @impl true
    def write(_handle, _output), do: raise("draw failed")

    @impl true
    def size(_handle), do: {:ok, {20, 6}}

    @impl true
    def close(handle) do
      send(handle.test_pid, :raising_adapter_close_attempted)
      raise "close failed"
    end
  end

  test "uses an injected adapter for all effects" do
    assert {:ok, terminal} =
             Terminal.open(adapter: FakeAdapter, adapter_opts: [test_pid: self()])

    assert_received {:opened, owner, ref}
    assert owner == self()
    assert ref == terminal.ref
    assert terminal.size == {20, 6}

    assert :ok = Terminal.draw(terminal, Frame.new(20, 6, ["Jido"]))
    assert_receive {:write, output}
    assert output =~ "Jido"

    assert {:ok, resized} = Terminal.resize(terminal)
    assert resized.size == {20, 6}
    assert :ok = Terminal.close(terminal)
    assert_receive :closed
  end

  test "normalizes adapter failures and still attempts close" do
    assert {:ok, terminal} =
             Terminal.open(adapter: RaisingAdapter, adapter_opts: [test_pid: self()])

    assert {:error, %RuntimeError{message: "draw failed"}} =
             Terminal.draw(terminal, Frame.new(20, 6, ["Jido"]))

    assert :ok = Terminal.close(terminal)
    assert_receive :raising_adapter_close_attempted
  end
end
