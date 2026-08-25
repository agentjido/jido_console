defmodule Jido.Console.Session.Client.JSON do
  @moduledoc "Experimental multi-thread JSONL client for Session.Client."

  use GenServer

  alias Jido.Console.Session.{Command, View}
  alias Jido.Console.Session.Client.JSON.{Attachment, Protocol}

  @default_max_threads 32
  @read_chunk_bytes 8_192

  @doc "Runs the JSON client until stdin reaches EOF or an IO operation fails."
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    caller = self()

    case start_link(Keyword.put(opts, :result_owner, caller)) do
      {:ok, pid} ->
        receive do
          {:jido_json_result, ^pid, result} -> result
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = self()
    input = Keyword.get(opts, :input_device, :stdio)
    output = Keyword.get(opts, :output_device, :stdio)
    max_bytes = Keyword.get(opts, :max_record_bytes, Protocol.default_max_bytes())
    write_fun = Keyword.get(opts, :write_fun, &safe_binwrite/2)

    reader = spawn_link(fn -> reader_loop(owner, input, max_bytes, %{buffer: <<>>, eof?: false}) end)
    writer = spawn_link(fn -> writer_loop(owner, output, write_fun) end)

    session_options =
      Keyword.get_lazy(opts, :session_options, fn ->
        Keyword.drop(opts, [
          :id_generator,
          :input_device,
          :max_record_bytes,
          :max_threads,
          :output_device,
          :result_owner,
          :session_options,
          :write_fun
        ])
      end)

    state = %{
      result_owner: Keyword.fetch!(opts, :result_owner),
      reader: reader,
      writer: writer,
      session_options: session_options,
      id_generator: Keyword.get(opts, :id_generator, &Jidoka.Id.generate!/1),
      max_bytes: max_bytes,
      max_threads: Keyword.get(opts, :max_threads, @default_max_threads),
      attachments: %{},
      attachment_threads: %{},
      ready: MapSet.new(),
      output: :queue.new(),
      writer_busy: nil,
      closing: nil,
      finish_scheduled?: false
    }

    send(reader, :read)
    {:ok, state}
  end

  @impl true
  def handle_info({:json_input, _reader, line}, %{closing: nil} = state) do
    state =
      case Protocol.decode(line, max_bytes: state.max_bytes) do
        {:ok, input} -> dispatch(input, state)
        {:error, reason, identity} -> enqueue_record(state, Protocol.failure(identity, reason), true)
      end

    continue(state)
  rescue
    exception ->
      state = enqueue_record(state, Protocol.failure(nil, exception), true)
      continue(state)
  end

  def handle_info({:json_input, _reader, _line}, state), do: {:noreply, state}

  def handle_info({:json_input_error, _reader, reason}, %{closing: nil} = state),
    do: continue(enqueue_record(state, Protocol.failure(nil, reason), true))

  def handle_info({:json_input_error, _reader, _reason}, state), do: {:noreply, state}

  def handle_info({:json_input_eof, _reader}, %{closing: nil} = state) do
    state = state |> collect_pending_views() |> close_all_attachments() |> Map.put(:closing, :ok)
    continue(state)
  end

  def handle_info({:json_input_eof, _reader}, state), do: {:noreply, state}

  def handle_info({:json_input_failed, _reader, reason}, state),
    do: continue(fail_stream(state, {:input_failed, reason}))

  def handle_info(
        {:json_writer_result, _writer, reference, :ok},
        %{writer_busy: %{ref: reference} = item} = state
      ) do
    if item.resume_reader? and is_nil(state.closing), do: send(state.reader, :read)
    continue(%{state | writer_busy: nil})
  end

  def handle_info(
        {:json_writer_result, _writer, reference, {:error, reason}},
        %{writer_busy: %{ref: reference}} = state
      ),
      do: continue(fail_stream(%{state | writer_busy: nil}, {:output_failed, reason}))

  def handle_info({:json_attachment_ready, pid}, %{closing: nil} = state) do
    if Map.has_key?(state.attachment_threads, pid),
      do: continue(%{state | ready: MapSet.put(state.ready, pid)}),
      else: {:noreply, state}
  end

  def handle_info({:json_attachment_ready, _pid}, state), do: {:noreply, state}

  def handle_info({:json_attachment_lifecycle, pid, event, data}, %{closing: nil} = state) do
    if Map.has_key?(state.attachment_threads, pid) do
      record =
        Protocol.lifecycle(
          Atom.to_string(event),
          data.thread_id,
          data.attachment_id,
          data.previous_attachment_id,
          data.reason
        )

      continue(enqueue_record(state, record, false))
    else
      {:noreply, state}
    end
  end

  def handle_info({:json_attachment_lifecycle, _pid, _event, _data}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, :normal}, state) do
    cond do
      pid in [state.reader, state.writer] -> {:noreply, state}
      Map.has_key?(state.attachment_threads, pid) -> continue(drop_attachment(state, pid))
      true -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      pid == state.reader ->
        continue(fail_stream(state, {:input_process_exit, reason}))

      pid == state.writer ->
        continue(fail_stream(%{state | writer_busy: nil}, {:output_process_exit, reason}))

      Map.has_key?(state.attachment_threads, pid) ->
        continue(attachment_failed(state, pid, reason))

      true ->
        {:noreply, state}
    end
  end

  def handle_info(:finish, state) do
    send(state.result_owner, {:jido_json_result, self(), state.closing || :ok})
    send(state.reader, :stop)
    send(state.writer, :stop)
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.attachments, fn {_thread_id, pid} -> Attachment.close(pid) end)
    :ok
  end

  defp dispatch(%{"type" => "attach"} = input, state), do: attach(input, state)
  defp dispatch(%{"type" => "reattach"} = input, state), do: reattach(input, state)
  defp dispatch(%{"type" => "detach"} = input, state), do: detach(input, state)
  defp dispatch(input, state), do: run_command(input, state)

  defp attach(%{"thread_id" => thread_id} = input, state) do
    cond do
      Map.has_key?(state.attachments, thread_id) ->
        enqueue_record(state, Protocol.failure(input, :already_attached), true)

      map_size(state.attachments) >= state.max_threads ->
        enqueue_record(state, Protocol.failure(input, :too_many_attachments), true)

      true ->
        opts = [
          driver: self(),
          thread_id: thread_id,
          owner_options: state.session_options,
          id_generator: state.id_generator
        ]

        case Attachment.start_link(opts) do
          {:ok, pid, identity} ->
            state = put_attachment(state, thread_id, pid)
            result = Protocol.success(input, attachment_data(identity))
            enqueue_result_and_view(state, pid, result)

          {:error, reason} ->
            enqueue_record(state, Protocol.failure(input, reason), true)
        end
    end
  end

  defp reattach(%{"thread_id" => thread_id} = input, state) do
    with {:ok, pid} <- fetch_attachment(state, thread_id),
         {:ok, identity} <- Attachment.reattach(pid) do
      result = Protocol.success(input, attachment_data(identity))
      enqueue_result_and_view(state, pid, result)
    else
      {:error, reason} -> enqueue_record(state, Protocol.failure(input, reason), true)
    end
  end

  defp detach(%{"thread_id" => thread_id} = input, state) do
    case fetch_attachment(state, thread_id) do
      {:ok, pid} ->
        state = drop_attachment(state, pid)
        Attachment.close(pid)
        enqueue_record(state, Protocol.success(input, %{"status" => "detached"}), true)

      {:error, reason} ->
        enqueue_record(state, Protocol.failure(input, reason), true)
    end
  end

  defp run_command(%{"thread_id" => thread_id} = input, state) do
    with {:ok, pid} <- fetch_attachment(state, thread_id),
         {:ok, %Command{} = command} <- Protocol.command(input) do
      apply_command(input, pid, command, state)
    else
      {:error, reason} -> enqueue_record(state, Protocol.failure(input, reason), true)
    end
  end

  defp apply_command(%{"type" => "status"} = input, pid, command, state) do
    case Attachment.command(pid, command) do
      {:ok, %View{} = view} ->
        :ok = Attachment.publish_view(pid, view)
        {:ok, identity} = Attachment.identity(pid)

        result =
          Protocol.success(input, %{
            "attachment_id" => identity.attachment_id,
            "revision" => view.revision
          })

        enqueue_result_and_view(state, pid, result)

      {:error, reason} ->
        enqueue_record(state, Protocol.failure(input, reason), true)
    end
  end

  defp apply_command(%{"type" => "stop", "thread_id" => thread_id} = input, pid, command, state) do
    case Attachment.command(pid, command) do
      :ok ->
        state = drop_attachment(state, pid)
        Attachment.close(pid)
        enqueue_record(state, Protocol.success(input, %{"status" => "stopped"}), true)

      {:error, reason} ->
        enqueue_record(state, Protocol.failure(input, reason), true)

      other ->
        enqueue_record(state, Protocol.failure(input, {:invalid_stop_result, thread_id, other}), true)
    end
  end

  defp apply_command(input, pid, command, state) do
    case Attachment.command(pid, command) do
      {:ok, result} ->
        data = result_data(input["type"], result)
        enqueue_record(state, Protocol.success(input, data), true)

      {:error, reason} ->
        enqueue_record(state, Protocol.failure(input, reason), true)

      other ->
        enqueue_record(state, Protocol.failure(input, {:invalid_command_result, other}), true)
    end
  end

  defp enqueue_result_and_view(state, pid, result) do
    state = enqueue_record(state, result, false)

    case Attachment.take_view(pid) do
      {:ok, output} -> enqueue_view_output(state, pid, output, true)
      :empty -> enqueue_resume(state)
    end
  end

  defp result_data(type, result) when type in ["cancel", "approve", "deny", "remove"],
    do: %{"status" => result}

  defp result_data(_type, result), do: result

  defp attachment_data(identity) do
    %{
      "attachment_id" => identity.attachment_id,
      "previous_attachment_id" => identity.previous_attachment_id
    }
  end

  defp fetch_attachment(state, thread_id) do
    case Map.fetch(state.attachments, thread_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, :not_attached}
    end
  end

  defp put_attachment(state, thread_id, pid) do
    %{
      state
      | attachments: Map.put(state.attachments, thread_id, pid),
        attachment_threads: Map.put(state.attachment_threads, pid, thread_id)
    }
  end

  defp drop_attachment(state, pid) do
    case Map.pop(state.attachment_threads, pid) do
      {nil, _threads} ->
        state

      {thread_id, threads} ->
        %{
          state
          | attachments: Map.delete(state.attachments, thread_id),
            attachment_threads: threads,
            ready: MapSet.delete(state.ready, pid)
        }
    end
  end

  defp attachment_failed(state, pid, reason) do
    thread_id = Map.fetch!(state.attachment_threads, pid)
    state = drop_attachment(state, pid)
    record = Protocol.lifecycle("detached", thread_id, nil, nil, {:attachment_process_exit, reason})
    enqueue_record(state, record, false)
  end

  defp collect_pending_views(state) do
    Enum.reduce(Map.values(state.attachments), state, fn pid, result ->
      case Attachment.take_view(pid) do
        {:ok, output} -> enqueue_view_output(result, pid, output, false)
        :empty -> result
      end
    end)
  end

  defp close_all_attachments(state) do
    Enum.each(state.attachments, fn {_thread_id, pid} -> Attachment.close(pid) end)
    %{state | attachments: %{}, attachment_threads: %{}, ready: MapSet.new()}
  end

  defp enqueue_record(state, record, resume_reader?) do
    case Protocol.encode(record, max_bytes: state.max_bytes) do
      {:ok, encoded} ->
        item = %{encoded: encoded, resume_reader?: resume_reader?}
        %{state | output: :queue.in(item, state.output)}

      {:error, {:output_too_large, size, limit}} ->
        if record["type"] == "result" and get_in(record, ["error", "code"]) != "result_too_large" do
          identity = %{"id" => record["id"], "thread_id" => record["thread_id"]}
          compact = Protocol.failure(identity, {:result_too_large, size, limit})
          enqueue_record(state, compact, resume_reader?)
        else
          fail_stream(state, {:output_too_large, size, limit})
        end

      {:error, reason} ->
        fail_stream(state, {:output_encoding_failed, reason})
    end
  end

  defp enqueue_resume(state) do
    item = %{encoded: nil, resume_reader?: true}
    %{state | output: :queue.in(item, state.output)}
  end

  defp enqueue_view_output(state, pid, output, resume_reader?) do
    gap_record =
      case output.gap do
        {first, last} -> Protocol.gap(output.thread_id, output.attachment_id, first, last)
        nil -> nil
      end

    case portable_view_record(output) do
      {:ok, record} -> enqueue_portable_view(state, pid, output, record, gap_record, resume_reader?)
      {:error, reason} -> detach_invalid_view(state, pid, output, {:invalid_view, reason}, resume_reader?)
    end
  end

  defp enqueue_portable_view(state, pid, output, record, gap_record, resume_reader?) do
    case Protocol.encode(record, max_bytes: state.max_bytes) do
      {:ok, encoded} ->
        state = if gap_record, do: enqueue_record(state, gap_record, false), else: state
        item = %{encoded: encoded, resume_reader?: resume_reader?}
        %{state | output: :queue.in(item, state.output)}

      {:error, {:output_too_large, size, limit}} ->
        detach_invalid_view(state, pid, output, {:view_too_large, size, limit}, resume_reader?)

      {:error, reason} ->
        detach_invalid_view(state, pid, output, {:invalid_view, reason}, resume_reader?)
    end
  end

  defp portable_view_record(output) do
    with {:ok, view} <- Protocol.portable(output.view) do
      {:ok,
       %{
         "version" => Protocol.version(),
         "type" => "view",
         "thread_id" => output.thread_id,
         "attachment_id" => output.attachment_id,
         "view" => view
       }}
    end
  end

  defp detach_invalid_view(state, pid, output, reason, resume_reader?) do
    state = drop_attachment(state, pid)
    Attachment.close(pid)
    lifecycle = Protocol.lifecycle("detached", output.thread_id, nil, output.attachment_id, reason)
    enqueue_record(state, lifecycle, resume_reader?)
  end

  defp maybe_write(%{writer_busy: busy} = state) when not is_nil(busy), do: state

  defp maybe_write(state) do
    case :queue.out(state.output) do
      {{:value, %{encoded: nil, resume_reader?: resume?}}, output} ->
        if resume? and is_nil(state.closing), do: send(state.reader, :read)
        maybe_write(%{state | output: output})

      {{:value, item}, output} ->
        reference = make_ref()
        send(state.writer, {:write, reference, item.encoded})
        %{state | output: output, writer_busy: Map.put(item, :ref, reference)}

      {:empty, _output} ->
        pull_ready_view(state)
    end
  end

  defp pull_ready_view(%{ready: ready} = state) do
    case Enum.at(ready, 0) do
      nil ->
        schedule_finish(state)

      pid ->
        state = %{state | ready: MapSet.delete(ready, pid)}

        if Map.has_key?(state.attachment_threads, pid) do
          case Attachment.take_view(pid) do
            {:ok, output} -> state |> enqueue_view_output(pid, output, false) |> maybe_write()
            :empty -> maybe_write(state)
          end
        else
          maybe_write(state)
        end
    end
  end

  defp schedule_finish(%{closing: nil} = state), do: state
  defp schedule_finish(%{finish_scheduled?: true} = state), do: state

  defp schedule_finish(state) do
    send(self(), :finish)
    %{state | finish_scheduled?: true}
  end

  defp fail_stream(%{closing: nil} = state, {:output_failed, _reason} = reason) do
    state
    |> close_all_attachments()
    |> Map.put(:output, :queue.new())
    |> Map.put(:ready, MapSet.new())
    |> Map.put(:closing, {:error, reason})
  end

  defp fail_stream(%{closing: nil} = state, {:output_process_exit, _reason} = reason) do
    state
    |> close_all_attachments()
    |> Map.put(:output, :queue.new())
    |> Map.put(:ready, MapSet.new())
    |> Map.put(:closing, {:error, reason})
  end

  defp fail_stream(%{closing: nil} = state, reason) do
    state
    |> close_all_attachments()
    |> Map.put(:ready, MapSet.new())
    |> Map.put(:closing, {:error, reason})
    |> maybe_enqueue_fatal(reason)
  end

  defp fail_stream(state, _reason), do: state

  defp maybe_enqueue_fatal(state, reason) do
    case Protocol.encode(Protocol.fatal(reason), max_bytes: state.max_bytes) do
      {:ok, encoded} ->
        item = %{encoded: encoded, resume_reader?: false}
        %{state | output: :queue.in(item, state.output)}

      {:error, _reason} ->
        state
    end
  end

  defp continue(state), do: {:noreply, maybe_write(state)}

  defp reader_loop(owner, device, max_bytes, input) do
    receive do
      :read ->
        case next_input(device, input, max_bytes) do
          {:line, line, input} ->
            send(owner, {:json_input, self(), line})
            reader_loop(owner, device, max_bytes, input)

          {:error, reason, input} ->
            send(owner, {:json_input_error, self(), reason})
            reader_loop(owner, device, max_bytes, input)

          {:eof, _input} ->
            send(owner, {:json_input_eof, self()})

          {:io_error, reason} ->
            send(owner, {:json_input_failed, self(), reason})
        end

      :stop ->
        :ok
    end
  end

  defp next_input(_device, %{buffer: <<>>, eof?: true} = input, _max_bytes), do: {:eof, input}

  defp next_input(device, %{buffer: buffer} = input, max_bytes) do
    case :binary.match(buffer, "\n") do
      {index, 1} ->
        size = index + 1
        <<line::binary-size(^size), rest::binary>> = buffer
        input = %{input | buffer: rest}

        if size <= max_bytes,
          do: {:line, line, input},
          else: {:error, {:input_too_large, size, max_bytes}, input}

      :nomatch when byte_size(buffer) > max_bytes ->
        discard_oversized_input(device, %{input | buffer: <<>>}, max_bytes, byte_size(buffer))

      :nomatch ->
        continue_input_read(device, input, buffer, max_bytes)
    end
  end

  defp continue_input_read(device, %{eof?: false} = input, buffer, max_bytes) do
    case safe_binread(device, @read_chunk_bytes) do
      data when is_binary(data) -> next_input(device, %{input | buffer: buffer <> data}, max_bytes)
      :eof -> next_input(device, %{input | eof?: true}, max_bytes)
      {:error, reason} -> {:io_error, reason}
    end
  end

  defp continue_input_read(_device, input, buffer, _max_bytes),
    do: {:line, buffer, %{input | buffer: <<>>}}

  defp discard_oversized_input(device, input, max_bytes, discarded_bytes) do
    case :binary.match(input.buffer, "\n") do
      {index, 1} ->
        size = index + 1
        rest_size = byte_size(input.buffer) - size
        rest = binary_part(input.buffer, size, rest_size)
        {:error, {:input_too_large, discarded_bytes + size, max_bytes}, %{input | buffer: rest}}

      :nomatch when input.eof? ->
        size = discarded_bytes + byte_size(input.buffer)
        {:error, {:input_too_large, size, max_bytes}, %{input | buffer: <<>>}}

      :nomatch ->
        case safe_binread(device, @read_chunk_bytes) do
          data when is_binary(data) ->
            discarded_bytes = discarded_bytes + byte_size(input.buffer)
            discard_oversized_input(device, %{input | buffer: data}, max_bytes, discarded_bytes)

          :eof ->
            discard_oversized_input(device, %{input | eof?: true}, max_bytes, discarded_bytes)

          {:error, reason} ->
            {:io_error, reason}
        end
    end
  end

  defp safe_binread(device, count) do
    IO.binread(device, count)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp writer_loop(owner, device, write_fun) do
    receive do
      {:write, reference, encoded} ->
        result = safe_write(write_fun, device, encoded)
        send(owner, {:json_writer_result, self(), reference, result})
        writer_loop(owner, device, write_fun)

      :stop ->
        :ok
    end
  end

  defp safe_write(write_fun, device, encoded) do
    write_fun.(device, encoded)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_binwrite(device, encoded) do
    IO.binwrite(device, encoded)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
