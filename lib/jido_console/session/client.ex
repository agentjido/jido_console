defmodule Jido.Console.Session.Client do
  @moduledoc "Small local client for the transport-neutral Command and View boundary."

  alias Jido.Console.Session.{BindingRequest, Command, Server, View}

  @schema Zoi.struct(
            __MODULE__,
            %{
              thread_id: Zoi.string() |> Zoi.min(1),
              attachment_ref: Zoi.any() |> Zoi.optional() |> Zoi.default(nil),
              owner_pid: Zoi.pid() |> Zoi.nullish(),
              owner_monitor: Zoi.any() |> Zoi.optional() |> Zoi.default(nil),
              owner_options: Zoi.any()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @opaque t :: %__MODULE__{
            thread_id: String.t(),
            attachment_ref: reference() | nil,
            owner_pid: pid() | nil,
            owner_monitor: reference() | nil,
            owner_options: keyword()
          }

  @type attach_result :: %{handle: t(), view: View.t()}

  @doc "Opens one thread and installs one view subscription."
  @spec attach(String.t(), keyword()) :: {:ok, attach_result()} | {:error, term()}
  def attach(thread_id, opts \\ []) when is_binary(thread_id) and thread_id != "" do
    subscriber = Keyword.get(opts, :subscriber, self())

    with {:ok, request} <- BindingRequest.from_options(opts),
         {:ok, owner} <- Server.ensure_started(thread_id, opts),
         {:ok, %{attachment_ref: attachment_ref, view: view}} <-
           Server.attach(owner, subscriber, request) do
      owner_monitor = Process.monitor(owner)

      result = %{
        handle: %__MODULE__{
          thread_id: thread_id,
          attachment_ref: attachment_ref,
          owner_pid: owner,
          owner_monitor: owner_monitor,
          owner_options: opts
        },
        view: view
      }

      {:ok, maybe_warnings(result, opts)}
    end
  catch
    :exit, reason -> {:error, {:session_owner_unavailable, reason}}
  end

  @doc "Installs a new attachment while retaining the same thread handle."
  @spec reattach(t(), keyword()) :: {:ok, attach_result()} | {:error, term()}
  def reattach(%__MODULE__{} = handle, opts \\ []) do
    _ = detach(handle)
    attach(handle.thread_id, Keyword.merge(handle.owner_options, opts))
  end

  @doc "Detaches one exact attachment without stopping thread work."
  @spec detach(t()) :: :ok | {:error, term()}
  def detach(%__MODULE__{attachment_ref: nil}), do: :ok

  def detach(%__MODULE__{} = handle) do
    demonitor_owner(handle)
    detach_owner(handle)
  end

  @doc "Builds a stable submit command that callers can retry unchanged."
  @spec submit_command(t(), String.t(), keyword()) :: {:ok, Command.t()} | {:error, term()}
  def submit_command(%__MODULE__{} = handle, text, opts \\ []) when is_binary(text) do
    command_id = Keyword.get_lazy(opts, :command_id, fn -> Jidoka.Id.generate!("command") end)
    request_id = Keyword.get_lazy(opts, :request_id, fn -> Jidoka.Id.generate!("request") end)

    Command.new(
      id: command_id,
      type: :submit,
      thread_id: handle.thread_id,
      queue_item_id: command_id,
      request_id: request_id,
      text: text,
      payload: %{"context" => Keyword.get(opts, :context, %{})}
    )
  end

  @doc "Submits a prompt with caller-stable IDs when supplied."
  @spec submit(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def submit(%__MODULE__{} = handle, text, opts \\ []) do
    with {:ok, command} <- submit_command(handle, text, opts) do
      run(handle, command)
    end
  end

  @doc "Runs one prebuilt command. The command can be retried unchanged."
  @spec run(t(), Command.t()) :: :ok | {:ok, term()} | {:error, term()}
  def run(%__MODULE__{thread_id: thread_id} = handle, %Command{thread_id: thread_id} = command) do
    run_owner(handle, command)
  end

  def run(%__MODULE__{}, %Command{}), do: {:error, :cross_thread_command}

  @doc "Requests cancellation for the current public request ID."
  @spec cancel(t(), String.t()) :: {:ok, :requested} | {:error, term()}
  def cancel(%__MODULE__{} = handle, request_id) do
    run(handle, control(handle, :cancel, request_id: request_id))
  end

  @doc "Approves one current public review ID."
  @spec approve(t(), String.t(), String.t()) :: {:ok, :requested} | {:error, term()}
  def approve(%__MODULE__{} = handle, request_id, review_id) do
    run(handle, control(handle, :approve, request_id: request_id, review_id: review_id))
  end

  @doc "Denies one current public review ID."
  @spec deny(t(), String.t(), String.t()) :: {:ok, :requested} | {:error, term()}
  def deny(%__MODULE__{} = handle, request_id, review_id) do
    run(handle, control(handle, :deny, request_id: request_id, review_id: review_id))
  end

  @doc "Removes one queued item by stable command ID."
  @spec remove(t(), String.t()) :: {:ok, :removed} | {:error, term()}
  def remove(%__MODULE__{} = handle, queue_item_id) do
    run(handle, control(handle, :remove, queue_item_id: queue_item_id))
  end

  @doc "Selects one exact model before the first prompt is durably accepted."
  @spec select_model(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def select_model(%__MODULE__{} = handle, identity) when is_binary(identity) do
    select_model_as(handle, identity, :api)
  end

  @doc false
  @spec select_model_as(t(), String.t(), :api | :tui) :: {:ok, map()} | {:error, term()}
  def select_model_as(%__MODULE__{} = handle, identity, origin)
      when is_binary(identity) and origin in [:api, :tui] do
    with {:ok, command} <-
           Command.new(
             id: Jidoka.Id.generate!("command"),
             type: :select_model,
             thread_id: handle.thread_id,
             text: identity,
             payload: %{"origin" => Atom.to_string(origin)}
           ) do
      run(handle, command)
    end
  end

  @doc "Selects one agent source before the first prompt is durably accepted."
  @spec select_agent(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def select_agent(%__MODULE__{} = handle, source) when is_binary(source) do
    select(handle, :select_agent, source)
  end

  @doc "Selects one execution policy before the first prompt is durably accepted."
  @spec select_execution_policy(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def select_execution_policy(%__MODULE__{} = handle, id, opts \\ []) when is_binary(id) do
    select_execution_policy_as(handle, id, :api, opts)
  end

  @doc false
  @spec select_execution_policy_as(t(), String.t(), :api | :tui, keyword()) ::
          {:ok, map()} | {:error, term()}
  def select_execution_policy_as(%__MODULE__{} = handle, id, origin, opts \\ [])
      when is_binary(id) and origin in [:api, :tui] do
    payload =
      %{"origin" => Atom.to_string(origin)}
      |> then(fn payload ->
        case Keyword.get(opts, :project_root) do
          nil -> payload
          root -> Map.put(payload, "project_root", root)
        end
      end)

    with {:ok, command} <-
           Command.new(
             id: Jidoka.Id.generate!("command"),
             type: :select_execution_policy,
             thread_id: handle.thread_id,
             text: id,
             payload: payload
           ) do
      run(handle, command)
    end
  end

  @doc "Returns the current complete view."
  @spec status(t()) :: {:ok, View.t()} | {:error, term()}
  def status(%__MODULE__{} = handle), do: run(handle, control(handle, :status))

  @doc "Reads one bounded older product-history page."
  @spec history(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def history(%__MODULE__{} = handle, opts \\ []) do
    payload =
      %{"limit" => Keyword.get(opts, :limit, 200)}
      |> maybe_put("before_sequence", Keyword.get(opts, :before_sequence))

    run(handle, control(handle, :history, payload: payload))
  end

  @doc "Stops an idle owner."
  @spec stop(t()) :: :ok | {:error, term()}
  def stop(%__MODULE__{} = handle), do: run(handle, control(handle, :stop))

  @doc "Returns the thread identity held by the opaque client handle."
  @spec thread_id(t()) :: String.t()
  def thread_id(%__MODULE__{thread_id: thread_id}), do: thread_id

  @doc "Returns the private attachment reference for mailbox matching."
  @spec attachment_ref(t()) :: reference() | nil
  def attachment_ref(%__MODULE__{attachment_ref: attachment_ref}), do: attachment_ref

  @doc "Returns true when a process-down message belongs to this handle's owner."
  @spec owner_down?(t(), term()) :: boolean()
  def owner_down?(
        %__MODULE__{owner_pid: owner, owner_monitor: monitor},
        {:DOWN, monitor, :process, owner, _reason}
      )
      when is_pid(owner) and is_reference(monitor),
      do: true

  def owner_down?(%__MODULE__{}, _message), do: false

  @doc false
  @spec owner_monitor(t()) :: reference() | nil
  def owner_monitor(%__MODULE__{owner_monitor: owner_monitor}), do: owner_monitor

  defp run_owner(
         %__MODULE__{owner_pid: owner, attachment_ref: attachment_ref},
         %Command{} = command
       )
       when is_pid(owner) and is_reference(attachment_ref) do
    if Process.alive?(owner) do
      Server.command(owner, attachment_ref, command)
    else
      {:error, :owner_unavailable}
    end
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  defp run_owner(%__MODULE__{}, %Command{}), do: {:error, :owner_unavailable}

  defp detach_owner(%__MODULE__{owner_pid: owner, attachment_ref: attachment_ref}) when is_pid(owner) do
    if Process.alive?(owner), do: Server.detach(owner, attachment_ref), else: :ok
  catch
    :exit, _reason -> :ok
  end

  defp detach_owner(%__MODULE__{}), do: :ok

  defp demonitor_owner(%__MODULE__{owner_monitor: monitor}) when is_reference(monitor) do
    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp demonitor_owner(%__MODULE__{}), do: :ok

  defp select(handle, type, value) do
    with {:ok, command} <-
           Command.new(
             id: Jidoka.Id.generate!("command"),
             type: type,
             thread_id: handle.thread_id,
             text: value,
             payload: %{"origin" => "api"}
           ) do
      run(handle, command)
    end
  end

  defp control(handle, type, attrs \\ []) do
    Command.new!(
      Keyword.merge(
        [id: Jidoka.Id.generate!("command"), type: type, thread_id: handle.thread_id, payload: %{}],
        attrs
      )
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_warnings(result, opts) do
    if Keyword.has_key?(opts, :coding_profile) or Keyword.has_key?(opts, :coding_profile_resolver) do
      Map.put(result, :warnings, [Jido.Console.ExecutionPolicy.legacy_warning()])
    else
      result
    end
  end
end
