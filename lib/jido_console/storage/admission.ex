defmodule Jido.Console.Storage.Admission do
  @moduledoc "Atomic operation, payload, page, and WAL admission for storage writes."

  use GenServer

  @normal_slots 112
  @control_slots 16
  @small_pool 16 * 1_024 * 1_024
  @large_lane 136 * 1_024 * 1_024
  @wal_soft 64 * 1_024 * 1_024
  @wal_hard 384 * 1_024 * 1_024

  @type lane :: :normal | :control

  @doc "Starts the admission owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the fixed admission limits."
  @spec limits() :: map()
  def limits do
    %{
      normal_slots: @normal_slots,
      control_slots: @control_slots,
      small_payload_bytes: @small_pool,
      normal_large_bytes: @large_lane,
      control_large_bytes: @large_lane,
      total_logical_payload_bytes: @small_pool + 2 * @large_lane,
      transactions: 1,
      wal_soft_bytes: @wal_soft,
      wal_hard_bytes: @wal_hard
    }
  end

  @doc "Atomically reserves a lane and its copied payload bytes."
  @spec reserve(GenServer.server(), lane(), non_neg_integer(), keyword()) ::
          {:ok, reference()} | {:error, term()}
  def reserve(server \\ __MODULE__, lane, payload_bytes, opts \\ []) do
    GenServer.call(server, {:reserve, lane, payload_bytes, opts})
  end

  @doc "Releases one exact reservation."
  @spec release(GenServer.server(), reference()) :: :ok
  def release(server \\ __MODULE__, token), do: GenServer.cast(server, {:release, token})

  @doc "Updates measured WAL bytes and checkpoint state."
  @spec wal(GenServer.server(), non_neg_integer(), :ready | :busy | :blocked) :: :ok
  def wal(server \\ __MODULE__, bytes, checkpoint) do
    GenServer.call(server, {:wal, bytes, checkpoint})
  end

  @doc "Returns counts only; reservation payloads are not exposed."
  @spec status(GenServer.server()) :: {:ok, map()}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(_opts) do
    {:ok,
     %{
       reservations: %{},
       counts: %{normal: 0, control: 0},
       small_bytes: 0,
       large: %{normal: false, control: false},
       page_bytes: 0,
       pending_wal_bytes: 0,
       wal_bytes: 0,
       checkpoint: :ready
     }}
  end

  @impl true
  def handle_call({:reserve, lane, payload, opts}, {caller, _tag}, state) do
    page_bytes = Keyword.get(opts, :page_bytes, 0)
    wal_bytes = Keyword.get(opts, :wal_bytes, 0)

    case admit(state, lane, payload, page_bytes, wal_bytes) do
      {:ok, class} ->
        token = make_ref()

        reservation = %{
          lane: lane,
          payload: payload,
          class: class,
          page: page_bytes,
          wal: wal_bytes,
          caller: caller,
          monitor: Process.monitor(caller)
        }

        {:reply, {:ok, token}, put_reservation(state, token, reservation)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:wal, bytes, checkpoint}, _from, state)
      when is_integer(bytes) and bytes >= 0 and checkpoint in [:ready, :busy, :blocked] do
    {:reply, :ok, %{state | wal_bytes: bytes, checkpoint: checkpoint}}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     {:ok,
      %{
        normal_operations: state.counts.normal,
        control_operations: state.counts.control,
        small_payload_bytes: state.small_bytes,
        normal_large?: state.large.normal,
        control_large?: state.large.control,
        page_bytes: state.page_bytes,
        pending_wal_bytes: state.pending_wal_bytes,
        wal_bytes: state.wal_bytes,
        checkpoint: state.checkpoint,
        limits: limits()
      }}, state}
  end

  @impl true
  def handle_cast({:release, token}, state) do
    case Map.pop(state.reservations, token) do
      {nil, _reservations} ->
        {:noreply, state}

      {reservation, reservations} ->
        Process.demonitor(reservation.monitor, [:flush])
        {:noreply, drop_reservation(state, reservations, reservation)}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, caller, _reason}, state) do
    {released, retained} =
      Enum.split_with(state.reservations, fn {_token, reservation} ->
        reservation.monitor == monitor and reservation.caller == caller
      end)

    state =
      Enum.reduce(released, %{state | reservations: Map.new(retained)}, fn {_token, reservation}, current ->
        drop_reservation(current, current.reservations, reservation)
      end)

    {:noreply, state}
  end

  defp admit(state, lane, payload, page, wal)
       when lane in [:normal, :control] and is_integer(payload) and payload >= 0 and
              is_integer(page) and page >= 0 and is_integer(wal) and wal >= 0 do
    with :ok <- admit_slot(state, lane),
         :ok <- admit_wal(state, lane, page) do
      admit_payload(state, lane, payload)
    end
  end

  defp admit(_state, _lane, _payload, _page, _wal), do: {:error, :invalid_storage_reservation}

  defp admit_slot(state, :normal) when state.counts.normal >= @normal_slots,
    do: {:error, {:storage_busy, :normal_slots}}

  defp admit_slot(state, :control) when state.counts.control >= @control_slots,
    do: {:error, {:storage_busy, :control_slots}}

  defp admit_slot(_state, _lane), do: :ok

  defp admit_wal(state, _lane, page) when page > 0 and state.checkpoint == :blocked,
    do: {:error, {:storage_busy, :wal_blocked}}

  defp admit_wal(state, _lane, page) when page > 0 and state.wal_bytes + state.pending_wal_bytes >= @wal_hard,
    do: {:error, {:storage_busy, :wal_hard_limit}}

  defp admit_wal(state, :normal, _page)
       when state.checkpoint == :busy or state.wal_bytes + state.pending_wal_bytes >= @wal_soft,
       do: {:error, {:storage_busy, :checkpoint_required}}

  defp admit_wal(_state, _lane, _page), do: :ok

  defp admit_payload(state, lane, payload) when payload <= @small_pool do
    if state.small_bytes + payload <= @small_pool do
      {:ok, :small}
    else
      admit_large(state, lane, payload)
    end
  end

  defp admit_payload(state, lane, payload), do: admit_large(state, lane, payload)

  defp admit_large(state, lane, payload) when payload <= @large_lane do
    if state.large[lane], do: {:error, {:storage_busy, {lane, :large_lane}}}, else: {:ok, :large}
  end

  defp admit_large(_state, lane, payload), do: {:error, {:storage_capacity, lane, payload, @large_lane}}

  defp put_reservation(state, token, reservation) do
    state
    |> Map.put(:reservations, Map.put(state.reservations, token, reservation))
    |> Map.put(:counts, Map.update!(state.counts, reservation.lane, &(&1 + 1)))
    |> add_payload(reservation, 1)
    |> Map.update!(:page_bytes, &(&1 + reservation.page))
    |> Map.update!(:pending_wal_bytes, &(&1 + reservation.wal))
  end

  defp drop_reservation(state, reservations, reservation) do
    state
    |> Map.put(:reservations, reservations)
    |> Map.put(:counts, Map.update!(state.counts, reservation.lane, &(&1 - 1)))
    |> add_payload(reservation, -1)
    |> Map.update!(:page_bytes, &max(&1 - reservation.page, 0))
    |> Map.update!(:pending_wal_bytes, &max(&1 - reservation.wal, 0))
  end

  defp add_payload(state, %{class: :small, payload: payload}, direction),
    do: Map.update!(state, :small_bytes, &(&1 + direction * payload))

  defp add_payload(state, %{class: :large, lane: lane}, direction) do
    Map.put(state, :large, Map.put(state.large, lane, direction > 0))
  end
end
