defmodule Jido.Console.Automation.InterruptTest do
  use ExUnit.Case, async: false

  alias Jido.Console.Automation.Interrupt
  alias Jido.Console.Automation.Interrupt.Signal

  defmodule Source do
    @behaviour Jido.Console.Automation.Interrupt

    @impl true
    def start(owner, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:source_started, owner})
      {:ok, test_pid}
    end

    @impl true
    def stop(test_pid) do
      send(test_pid, :source_stopped)
      :not_ok
    end
  end

  defmodule InvalidSource do
    @behaviour Jido.Console.Automation.Interrupt

    @impl true
    def start(_owner, _opts), do: :invalid

    @impl true
    def stop(_state), do: raise("stop failed")
  end

  test "starts, requests, and stops module and function sources" do
    assert {:ok, nil} = Interrupt.start(self(), [])
    assert :ok = Interrupt.stop(nil)

    assert {:ok, {:module, Source, test_pid}} =
             Interrupt.start(self(), cancellation_source: Source, test_pid: self())

    assert test_pid == self()
    assert_receive {:source_started, owner}
    assert owner == self()
    assert :ok = Interrupt.request(owner, :test)
    assert_receive {tag, :test}
    assert tag == Interrupt.message_tag()
    assert :ok = Interrupt.stop({:module, Source, self()})
    assert_receive :source_stopped

    cleanup = fn -> send(self(), :function_stopped) end
    source = fn _owner -> {:ok, cleanup} end
    assert {:ok, {:function, ^cleanup}} = Interrupt.start(self(), cancellation_source: source)
    assert :ok = Interrupt.stop({:function, cleanup})
    assert_receive :function_stopped
  end

  test "normalizes invalid, failed, raised, and thrown sources" do
    assert {:error, {:invalid_cancellation_source, 42}} =
             Interrupt.start(self(), cancellation_source: 42)

    assert {:error, {:invalid_cancellation_source, String}} =
             Interrupt.start(self(), cancellation_source: String)

    assert {:error, {:invalid_cancellation_source_start, InvalidSource, :invalid}} =
             Interrupt.start(self(), cancellation_source: InvalidSource)

    assert {:error, :fixture} =
             Interrupt.start(self(), cancellation_source: fn _owner -> {:error, :fixture} end)

    assert {:error, {:invalid_cancellation_source_start, :invalid}} =
             Interrupt.start(self(), cancellation_source: fn _owner -> :invalid end)

    assert {:error, {:cancellation_source_failed, %RuntimeError{}}} =
             Interrupt.start(self(), cancellation_source: fn _owner -> raise "failed" end)

    assert {:error, {:cancellation_source_failed, {:throw, :failed}}} =
             Interrupt.start(self(), cancellation_source: fn _owner -> throw(:failed) end)

    assert :ok = Interrupt.stop({:module, InvalidSource, nil})
    assert :ok = Interrupt.stop({:function, fn -> raise "cleanup" end})
    assert :ok = Interrupt.stop({:function, fn -> throw(:cleanup) end})
  end

  test "the signal callback converts SIGTERM and supports gen_event callbacks" do
    assert {:ok, owner} = Signal.init(self())
    assert {:ok, ^owner} = Signal.handle_event(:other, owner)
    assert {:ok, ^owner} = Signal.handle_event(:sigterm, owner)
    assert_receive {tag, :sigterm}
    assert tag == Interrupt.message_tag()
    assert {:ok, :ok, ^owner} = Signal.handle_call(:request, owner)
    assert {:ok, ^owner} = Signal.handle_info(:message, owner)
    assert :ok = Signal.terminate(:normal, owner)
    assert {:ok, ^owner} = Signal.code_change(:old, owner, :extra)
    assert :ok = Signal.stop(%{handler: nil})
  end

  test "installs and restores the process SIGTERM handler" do
    assert {:ok, state} = Signal.start(self(), [])
    assert :ok = Signal.stop(state)
  end
end
