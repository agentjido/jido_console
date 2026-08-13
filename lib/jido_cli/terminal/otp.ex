defmodule Jido.Terminal.OTP do
  @moduledoc "OTP 28+ terminal adapter for an escript."

  @behaviour Jido.Terminal.Adapter

  use GenServer

  alias Jido.Terminal.Input

  @enter "\e[?1049h\e[?25l\e[?2004h\e[2J\e[H"
  @leave "\e[?2004l\e[0m\e[?25h\e[?1049l"
  @escape_timeout_ms 20
  @resize_interval_ms 150

  defmodule Handle do
    @moduledoc false
    @enforce_keys [:pid]
    defstruct [:pid]
  end

  defmodule Reader do
    @moduledoc false

    def start_link(parent, read), do: Task.start_link(fn -> loop(parent, read) end)

    def start_link(parent, start_raw, read) do
      Task.start_link(fn ->
        case start_raw.() do
          :ok ->
            send(parent, {:terminal_reader_ready, self()})
            loop(parent, read)

          {:error, reason} ->
            send(parent, {:terminal_reader_failed, self(), reason})
        end
      end)
    end

    defp loop(parent, read) do
      case read.() do
        data when is_binary(data) and data != "" ->
          send(parent, {:terminal_bytes, data})
          loop(parent, read)

        data when is_list(data) and data != [] ->
          send(parent, {:terminal_bytes, IO.chardata_to_string(data)})
          loop(parent, read)

        :eof ->
          send(parent, :terminal_eof)

        {:error, reason} ->
          send(parent, {:terminal_error, reason})

        _other ->
          loop(parent, read)
      end
    end
  end

  @impl Jido.Terminal.Adapter
  def open(owner, opts) when is_pid(owner) and is_list(opts) do
    case GenServer.start(__MODULE__, {owner, opts}) do
      {:ok, pid} ->
        {ref, size} = GenServer.call(pid, :describe)
        {:ok, %Handle{pid: pid}, ref, size}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Jido.Terminal.Adapter
  def write(%Handle{pid: pid}, output) do
    if Process.alive?(pid), do: GenServer.call(pid, {:write, output}), else: {:error, :closed}
  end

  @impl Jido.Terminal.Adapter
  def size(%Handle{pid: pid}) do
    if Process.alive?(pid), do: GenServer.call(pid, :size), else: {:error, :closed}
  end

  @impl Jido.Terminal.Adapter
  def close(%Handle{pid: pid}) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init({owner, opts}) do
    Process.flag(:trap_exit, true)
    effects = effects(opts)

    with :ok <- require_otp_28(effects.otp_release),
         {:ok, reader} <-
           effects.reader.start_link(
             self(),
             fn -> start_raw_shell(effects.start_raw) end,
             effects.read
           ),
         :ok <- await_reader_start(reader),
         {:ok, size} <- read_size(effects.size),
         :ok <- write_stdio(effects.write, @enter) do
      state = %{
        effects: effects,
        owner: owner,
        owner_monitor: Process.monitor(owner),
        reader: reader,
        ref: make_ref(),
        input: %Input{},
        escape_timer: nil,
        size: size
      }

      {:ok, schedule_resize(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:describe, _from, state), do: {:reply, {state.ref, state.size}, state}

  def handle_call(:size, _from, state) do
    case read_size(state.effects.size) do
      {:ok, size} -> {:reply, {:ok, size}, %{state | size: size}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:write, output}, _from, state) do
    {:reply, write_stdio(state.effects.write, output), state}
  end

  @impl GenServer
  def handle_info({:terminal_bytes, bytes}, state) do
    {input, events} = Input.feed(state.input, bytes)
    Enum.each(events, &emit(state, &1))
    {:noreply, schedule_escape(%{state | input: input})}
  end

  def handle_info({:flush_escape, timer}, %{escape_timer: timer} = state) do
    {input, events} = Input.flush_escape(state.input)
    Enum.each(events, &emit(state, &1))
    {:noreply, %{state | input: input, escape_timer: nil}}
  end

  def handle_info({:flush_escape, _old_timer}, state), do: {:noreply, state}

  def handle_info(:terminal_eof, state) do
    emit(state, :eof)
    {:noreply, state}
  end

  def handle_info({:terminal_error, _reason}, state) do
    emit(state, :eof)
    {:noreply, state}
  end

  def handle_info(:check_size, state) do
    state =
      case read_size(state.effects.size) do
        {:ok, size} when size != state.size ->
          {columns, rows} = size
          emit(state, {:resize, columns, rows})
          %{state | size: size}

        _other ->
          state
      end

    {:noreply, schedule_resize(state)}
  end

  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{owner_monitor: monitor} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, reader, _reason}, %{reader: reader} = state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if is_pid(state[:reader]) and Process.alive?(state.reader) do
      Process.unlink(state.reader)
      Process.exit(state.reader, :kill)
    end

    _result = write_stdio(state.effects.write, @leave)
    :ok
  end

  defp effects(opts) do
    %{
      escape_timeout_ms: Keyword.get(opts, :escape_timeout_ms, @escape_timeout_ms),
      otp_release: Keyword.get(opts, :otp_release, &System.otp_release/0),
      read: Keyword.get(opts, :read, fn -> IO.getn(:user, "", 1) end),
      reader: Keyword.get(opts, :reader, Reader),
      resize_interval_ms: Keyword.get(opts, :resize_interval_ms, @resize_interval_ms),
      size: Keyword.get(opts, :size, &system_size/0),
      start_raw: Keyword.get(opts, :start_raw, fn -> :shell.start_interactive({:noshell, :raw}) end),
      write: Keyword.get(opts, :write, &system_write/1)
    }
  end

  defp require_otp_28(otp_release) do
    release = otp_release.()

    if String.to_integer(release) >= 28,
      do: :ok,
      else: {:error, {:unsupported_otp, release}}
  end

  defp start_raw_shell(start_raw) do
    case start_raw.() do
      :ok -> :ok
      {:error, :already_started} -> {:error, :interactive_shell_already_started}
      {:error, reason} -> {:error, {:raw_terminal_failed, reason}}
    end
  end

  defp await_reader_start(reader) do
    receive do
      {:terminal_reader_ready, ^reader} -> :ok
      {:terminal_reader_failed, ^reader, reason} -> {:error, reason}
      {:EXIT, ^reader, reason} -> {:error, {:terminal_reader_failed, reason}}
    after
      5_000 -> {:error, :terminal_reader_start_timeout}
    end
  end

  defp read_size(size) do
    case size.() do
      {:ok, {columns, rows}} when columns > 0 and rows > 0 -> {:ok, {columns, rows}}
      _other -> {:error, :not_a_terminal}
    end
  rescue
    _exception -> {:error, :not_a_terminal}
  end

  defp system_size do
    with {:ok, columns} when columns > 0 <- :io.columns(),
         {:ok, rows} when rows > 0 <- :io.rows() do
      {:ok, {columns, rows}}
    else
      _other -> {:error, :not_a_terminal}
    end
  rescue
    _exception -> {:error, :not_a_terminal}
  end

  defp write_stdio(write, output) do
    write.(output)
  rescue
    exception -> {:error, exception}
  end

  defp system_write(output) do
    IO.write(:stdio, output)
    :ok
  rescue
    exception -> {:error, exception}
  end

  defp emit(state, event), do: send(state.owner, {:jido_terminal, state.ref, event})

  defp schedule_escape(state) do
    if Input.escape_pending?(state.input) do
      timer = make_ref()
      Process.send_after(self(), {:flush_escape, timer}, state.effects.escape_timeout_ms)
      %{state | escape_timer: timer}
    else
      %{state | escape_timer: nil}
    end
  end

  defp schedule_resize(state) do
    Process.send_after(self(), :check_size, state.effects.resize_interval_ms)
    state
  end
end
