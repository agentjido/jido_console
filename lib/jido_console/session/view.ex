defmodule Jido.Console.Session.View do
  @moduledoc "A complete, portable view of one Console thread."

  alias Jido.Console.Session.{Event, Queue, Selection}

  @statuses [:idle, :starting, :running, :review, :finishing, :reconciling, :unavailable]
  @binding_states [:needs_model, :needs_policy, :ready_unlocked, :locked, :reconciling, :resume_blocked]

  @schema Zoi.struct(
            __MODULE__,
            %{
              thread_id: Zoi.string() |> Zoi.min(1),
              status: Zoi.enum(@statuses),
              binding_state: Zoi.enum(@binding_states) |> Zoi.default(:ready_unlocked),
              binding: Zoi.map() |> Zoi.default(%{}),
              revision: Zoi.integer() |> Zoi.gte(0),
              session_revision: Zoi.integer() |> Zoi.gte(0) |> Zoi.optional() |> Zoi.default(0),
              transcript: Zoi.array(Zoi.map()) |> Zoi.default([]),
              history: Zoi.array(Zoi.map()) |> Zoi.default([]),
              history_truncated?: Zoi.boolean() |> Zoi.default(false),
              partial: Zoi.array(Zoi.map()) |> Zoi.default([]),
              active: Zoi.map() |> Zoi.optional() |> Zoi.default(nil),
              review: Zoi.map() |> Zoi.optional() |> Zoi.default(nil),
              queue: Zoi.array(Zoi.map()) |> Zoi.default([]),
              resources: Zoi.map() |> Zoi.default(%{"status" => "not_prepared"}),
              model: Zoi.map() |> Zoi.optional() |> Zoi.default(nil),
              error: Zoi.any() |> Zoi.optional() |> Zoi.default(nil)
            },
            coerce: true,
            unrecognized_keys: :error
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the view schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds and validates one complete view."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    case Zoi.parse(@schema, attrs) do
      {:ok, %__MODULE__{} = view} -> {:ok, view}
      {:error, _reason} -> {:error, :invalid_session_view}
    end
  end

  @doc "Builds one complete view and raises when it is invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, view} -> view
      {:error, reason} -> raise ArgumentError, "invalid session view: #{inspect(reason)}"
    end
  end

  @doc "Adds a subscriber before it captures the returned revision."
  @spec attach(map(), pid()) :: {reference(), t(), map()}
  def attach(state, subscriber) do
    attachment_ref = make_ref()
    monitor = Process.monitor(subscriber)
    current = from_thread(state)
    subscription = %{pid: subscriber, monitor: monitor, sent_revision: current.revision}

    state = %{
      state
      | subscribers: Map.put(state.subscribers, attachment_ref, subscription),
        monitors: Map.put(state.monitors, monitor, attachment_ref)
    }

    {attachment_ref, current, state}
  end

  @doc "Drops one exact attachment."
  @spec detach(map(), reference()) :: map()
  def detach(state, attachment_ref) do
    case Map.pop(state.subscribers, attachment_ref) do
      {nil, _subscribers} ->
        state

      {%{monitor: monitor}, subscribers} ->
        Process.demonitor(monitor, [:flush])
        %{state | subscribers: subscribers, monitors: Map.delete(state.monitors, monitor)}
    end
  end

  @doc "Drops a subscriber after its process exits."
  @spec subscriber_down(map(), reference()) :: map()
  def subscriber_down(state, monitor) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        state

      {attachment_ref, monitors} ->
        %{state | monitors: monitors, subscribers: Map.delete(state.subscribers, attachment_ref)}
    end
  end

  @doc "Publishes one complete revision to all attached subscribers."
  @spec publish(map()) :: map()
  def publish(state) do
    state = %{state | revision: state.revision + 1}
    current = from_thread(state)

    subscribers =
      Map.new(state.subscribers, fn {attachment_ref, subscription} ->
        if current.revision > subscription.sent_revision,
          do: send(subscription.pid, {:jido_console_view, attachment_ref, current})

        {attachment_ref, %{subscription | sent_revision: current.revision}}
      end)

    %{state | subscribers: subscribers}
  end

  @doc "Builds complete portable state from one private thread state."
  @spec from_thread(map()) :: t()
  def from_thread(state) do
    new!(
      thread_id: state.thread_id,
      status: state.status,
      binding_state: binding_state(state),
      binding: binding_projection(state),
      revision: state.revision,
      session_revision: state.session.revision,
      transcript: Enum.map(state.session.conversation.agent_state.messages, &Jidoka.project/1),
      history: Enum.map(state.history, &Event.to_view/1),
      history_truncated?: state.history_truncated?,
      partial: Enum.reverse(state.partial),
      active: item(state.active),
      review: review(state.review),
      queue: Enum.map(Queue.to_list(state.queue), &item/1),
      resources: resources(state),
      model: model(state),
      error: state.error
    )
  end

  defp review(nil), do: nil
  defp review(%{data: data}), do: data
  defp item(nil), do: nil
  defp item(value), do: %{"queue_item_id" => value.id, "request_id" => value.request_id, "input" => value.text}

  defp model(%{model: %{identity: identity, tier: tier}} = state) do
    %{
      "identity" => identity,
      "tier" => Atom.to_string(tier),
      "locked" => Map.get(state, :model_locked?, false)
    }
  end

  defp model(_state), do: nil

  defp binding_state(%{status: :reconciling, pending_lock: pending}) when not is_nil(pending),
    do: :reconciling

  defp binding_state(%{binding_state: state}), do: state
  defp binding_state(_state), do: :ready_unlocked

  defp binding_projection(%{selection: %Selection{} = selection}),
    do: Selection.safe_projection(selection)

  defp binding_projection(_state), do: %{}

  defp resources(%{resources: nil}), do: %{"status" => "not_prepared"}
  defp resources(state), do: state.resources_module.status(state.resources)
end
