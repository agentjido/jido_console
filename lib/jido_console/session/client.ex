defmodule Jido.Console.Session.Client do
  @moduledoc "Small local client for the transport-neutral Command and View boundary."

  alias Jido.Console.Session.{Command, Server, View}

  @schema Zoi.struct(
            __MODULE__,
            %{
              thread_id: Zoi.string() |> Zoi.min(1),
              attachment_ref: Zoi.any() |> Zoi.optional() |> Zoi.default(nil),
              owner_options: Zoi.any()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @opaque t :: %__MODULE__{
            thread_id: String.t(),
            attachment_ref: reference() | nil,
            owner_options: keyword()
          }

  @type attach_result :: %{handle: t(), view: View.t()}

  @doc "Opens one thread and installs one view subscription."
  @spec attach(String.t(), keyword()) :: {:ok, attach_result()} | {:error, term()}
  def attach(thread_id, opts \\ []) when is_binary(thread_id) and thread_id != "" do
    subscriber = Keyword.get(opts, :subscriber, self())

    with {:ok, owner} <- Server.ensure_started(thread_id, opts),
         {:ok, %{attachment_ref: attachment_ref, view: view}} <- Server.attach(owner, subscriber) do
      {:ok,
       %{
         handle: %__MODULE__{thread_id: thread_id, attachment_ref: attachment_ref, owner_options: opts},
         view: view
       }}
    end
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
    case owner(handle) do
      {:ok, owner} -> Server.detach(owner, handle.attachment_ref)
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
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
  @spec run(t(), Command.t()) :: {:ok, term()} | {:error, term()}
  def run(%__MODULE__{thread_id: thread_id} = handle, %Command{thread_id: thread_id} = command) do
    with {:ok, owner} <- owner(handle) do
      Server.command(owner, command)
    end
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
    run(handle, control(handle, :select_model, text: identity))
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

  defp owner(%__MODULE__{} = handle), do: Server.ensure_started(handle.thread_id, handle.owner_options)

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
end
