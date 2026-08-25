defmodule Jido.Console.Session.Client.JSON.Attachment do
  @moduledoc "Owns one exact Session.Client attachment for the JSONL client."

  use GenServer

  alias Jido.Console.Session.{Client, Command, View}

  @initial_retry_ms 100
  @max_retry_ms 5_000

  @type identity :: %{
          thread_id: String.t(),
          attachment_id: String.t(),
          previous_attachment_id: String.t() | nil
        }
  @type view_output :: %{
          thread_id: String.t(),
          attachment_id: String.t(),
          view: View.t(),
          gap: {non_neg_integer(), non_neg_integer()} | nil
        }

  @doc "Starts one linked attachment and returns its portable identity."
  @spec start_link(keyword()) :: {:ok, pid(), identity()} | {:error, term()}
  def start_link(opts) do
    case GenServer.start_link(__MODULE__, opts) do
      {:ok, pid} ->
        case GenServer.call(pid, :identity) do
          {:ok, identity} -> {:ok, pid, identity}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Runs one command through the exact client handle."
  @spec command(pid(), Command.t()) :: term()
  def command(pid, %Command{} = command), do: GenServer.call(pid, {:command, command}, 6_000)

  @doc "Replaces the current exact attachment."
  @spec reattach(pid()) :: {:ok, identity()} | {:error, term()}
  def reattach(pid), do: GenServer.call(pid, :reattach, 6_000)

  @doc "Takes the latest pending full view."
  @spec take_view(pid()) :: {:ok, view_output()} | :empty
  def take_view(pid), do: GenServer.call(pid, :take_view)

  @doc false
  @spec publish_view(pid(), View.t()) :: :ok
  def publish_view(pid, %View{} = view), do: GenServer.call(pid, {:publish_view, view})

  @doc "Returns the portable attachment identity."
  @spec identity(pid()) :: {:ok, identity()} | {:error, :reattaching}
  def identity(pid), do: GenServer.call(pid, :identity)

  @doc "Detaches and stops this attachment process."
  @spec close(pid()) :: :ok
  def close(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    driver = Keyword.fetch!(opts, :driver)
    thread_id = Keyword.fetch!(opts, :thread_id)
    owner_options = opts |> Keyword.fetch!(:owner_options) |> Keyword.put(:subscriber, self())
    id_generator = Keyword.get(opts, :id_generator, &Jidoka.Id.generate!/1)

    case Client.attach(thread_id, owner_options) do
      {:ok, %{handle: handle, view: view}} ->
        state = %{
          driver: driver,
          thread_id: thread_id,
          owner_options: owner_options,
          id_generator: id_generator,
          handle: handle,
          attachment_id: id_generator.("attachment"),
          previous_attachment_id: nil,
          phase: :attached,
          pending: nil,
          ready?: false,
          last_taken_revision: nil,
          retry_ms: @initial_retry_ms,
          retry_ref: nil,
          lifecycle_reported?: false
        }

        {:ok, offer_view(state, view)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:identity, _from, %{phase: :attached} = state),
    do: {:reply, {:ok, public_identity(state)}, state}

  def handle_call(:identity, _from, state), do: {:reply, {:error, :reattaching}, state}

  def handle_call({:command, _command}, _from, %{phase: :reattaching} = state),
    do: {:reply, {:error, :reattaching}, state}

  def handle_call({:command, %Command{type: :stop} = command}, _from, state) do
    case Client.run(state.handle, command) do
      :ok ->
        _ = Client.detach(state.handle)
        {:reply, :ok, %{state | phase: :detached, handle: nil, pending: nil, ready?: false}}

      result ->
        {:reply, result, state}
    end
  end

  def handle_call({:command, command}, _from, state),
    do: {:reply, Client.run(state.handle, command), state}

  def handle_call(:reattach, _from, %{phase: :reattaching} = state),
    do: {:reply, {:error, :reattaching}, state}

  def handle_call(:reattach, _from, state) do
    previous = state.attachment_id

    case Client.reattach(state.handle, subscriber: self()) do
      {:ok, %{handle: handle, view: view}} ->
        state = %{
          state
          | handle: handle,
            attachment_id: state.id_generator.("attachment"),
            previous_attachment_id: previous,
            pending: nil,
            ready?: false,
            last_taken_revision: nil,
            retry_ms: @initial_retry_ms,
            lifecycle_reported?: false
        }

        state = offer_view(state, view)
        {:reply, {:ok, public_identity(state)}, state}

      {:error, reason} ->
        state = begin_reattach(%{state | previous_attachment_id: previous, handle: nil})
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:take_view, _from, %{pending: nil} = state),
    do: {:reply, :empty, %{state | ready?: false}}

  def handle_call(:take_view, _from, %{pending: pending} = state) do
    output = %{
      thread_id: state.thread_id,
      attachment_id: state.attachment_id,
      view: pending.view,
      gap: pending.gap
    }

    state = %{state | pending: nil, ready?: false, last_taken_revision: pending.view.revision}
    {:reply, {:ok, output}, state}
  end

  def handle_call({:publish_view, %View{} = view}, _from, state),
    do: {:reply, :ok, offer_view(state, view)}

  @impl true
  def handle_info({:jido_console_view, attachment_ref, %View{} = view}, state) do
    if state.handle && Client.attachment_ref(state.handle) == attachment_ref,
      do: {:noreply, offer_view(state, view)},
      else: {:noreply, state}
  end

  def handle_info({:DOWN, _monitor, :process, _owner, _reason} = message, state) do
    if state.handle && Client.owner_down?(state.handle, message),
      do: {:noreply, begin_reattach(state)},
      else: {:noreply, state}
  end

  def handle_info(:retry_attach, %{phase: :reattaching} = state) do
    case Client.attach(state.thread_id, state.owner_options) do
      {:ok, %{handle: handle, view: view}} ->
        attachment_id = state.id_generator.("attachment")

        send_lifecycle(state, :reattached, %{
          thread_id: state.thread_id,
          attachment_id: attachment_id,
          previous_attachment_id: state.previous_attachment_id,
          reason: :owner_down
        })

        state = %{
          state
          | handle: handle,
            attachment_id: attachment_id,
            phase: :attached,
            pending: nil,
            ready?: false,
            last_taken_revision: nil,
            retry_ms: @initial_retry_ms,
            retry_ref: nil,
            lifecycle_reported?: false
        }

        {:noreply, offer_view(state, view)}

      {:error, _reason} ->
        retry_ref = Process.send_after(self(), :retry_attach, state.retry_ms)
        retry_ms = min(state.retry_ms * 2, @max_retry_ms)
        {:noreply, %{state | retry_ms: retry_ms, retry_ref: retry_ref}}
    end
  end

  def handle_info(:retry_attach, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_retry(state.retry_ref)
    if state.handle, do: Client.detach(state.handle)
    :ok
  end

  defp begin_reattach(%{phase: :reattaching} = state), do: state

  defp begin_reattach(state) do
    if state.handle, do: Client.detach(state.handle)
    cancel_retry(state.retry_ref)

    unless state.lifecycle_reported? do
      send_lifecycle(state, :reattaching, %{
        thread_id: state.thread_id,
        attachment_id: nil,
        previous_attachment_id: state.attachment_id,
        reason: :owner_down
      })
    end

    send(self(), :retry_attach)

    %{
      state
      | handle: nil,
        previous_attachment_id: state.attachment_id,
        phase: :reattaching,
        pending: nil,
        ready?: false,
        retry_ms: @initial_retry_ms,
        retry_ref: nil,
        lifecycle_reported?: true
    }
  end

  defp offer_view(%{phase: :attached} = state, %View{thread_id: thread_id} = view)
       when thread_id == state.thread_id do
    state = %{state | pending: merge_pending(state.pending, state.last_taken_revision, view)}

    if state.ready? do
      state
    else
      send(state.driver, {:json_attachment_ready, self()})
      %{state | ready?: true}
    end
  end

  defp offer_view(state, _view), do: state

  defp merge_pending(nil, last_taken, view) do
    gap =
      if is_integer(last_taken) and view.revision > last_taken + 1,
        do: {last_taken + 1, view.revision - 1},
        else: nil

    %{view: view, gap: gap}
  end

  defp merge_pending(%{view: previous, gap: existing}, _last_taken, view)
       when view.revision > previous.revision do
    {first, _last} = existing || {previous.revision, view.revision - 1}
    %{view: view, gap: {first, view.revision - 1}}
  end

  defp merge_pending(pending, _last_taken, _view), do: pending

  defp public_identity(state) do
    %{
      thread_id: state.thread_id,
      attachment_id: state.attachment_id,
      previous_attachment_id: state.previous_attachment_id
    }
  end

  defp send_lifecycle(state, event, data),
    do: send(state.driver, {:json_attachment_lifecycle, self(), event, data})

  defp cancel_retry(nil), do: :ok

  defp cancel_retry(reference) do
    Process.cancel_timer(reference)
    :ok
  end
end
