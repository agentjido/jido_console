defmodule Jido.Cli.TerminalTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Terminal
  alias Jido.Cli.Terminal.Frame

  defmodule FakeAdapter do
    @behaviour Jido.Cli.Terminal.Adapter

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
end
