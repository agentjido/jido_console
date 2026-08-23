defmodule Jido.Console.Tui.Turn do
  @moduledoc false

  alias Jido.Console.Tui.SafeText

  @assistant_limit 200_000
  @prompt_limit 65_536
  @event_limit 1_000
  @tool_limit 200
  @tool_event_limit 100
  @record_limit 100

  defmodule Tool do
    @moduledoc false

    @schema Zoi.struct(
              __MODULE__,
              %{
                id: Zoi.any(),
                operation: Zoi.string() |> Zoi.nullable(),
                status: Zoi.atom(),
                events: Zoi.array(Zoi.map()),
                summary: Zoi.string() |> Zoi.nullish(),
                error: Zoi.string() |> Zoi.nullish(),
                loop_index: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish()
              },
              unrecognized_keys: :error
            )

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)

    @type t :: %__MODULE__{
            id: term(),
            operation: String.t() | nil,
            status: atom(),
            events: [map()],
            summary: String.t() | nil,
            error: String.t() | nil,
            loop_index: non_neg_integer() | nil
          }
  end

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.integer() |> Zoi.gte(0),
              prompt: Zoi.string(),
              attachments: Zoi.array(Zoi.map()),
              assistant: Zoi.string(),
              tools: Zoi.map(Zoi.any(), Zoi.struct(Tool), []),
              tool_order: Zoi.array(),
              reviews: Zoi.array(Zoi.map()),
              outcome: Zoi.map() |> Zoi.nullable(),
              changes: Zoi.array(Zoi.map()),
              events: Zoi.array(Zoi.map()),
              seen_events: Zoi.struct(MapSet),
              status: Zoi.atom(),
              request_id: Zoi.string() |> Zoi.nullish(),
              last_seq: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          request_id: String.t() | nil,
          prompt: String.t(),
          attachments: [map()],
          assistant: String.t(),
          tools: %{optional(term()) => Tool.t()},
          tool_order: [term()],
          reviews: [map()],
          outcome: map() | nil,
          changes: [map()],
          events: [map()],
          seen_events: MapSet.t(),
          last_seq: non_neg_integer() | nil,
          status: atom()
        }

  @spec new(non_neg_integer(), String.t(), map()) :: t()
  def new(id, prompt, context \\ %{}) do
    %__MODULE__{
      id: id,
      prompt: prompt |> SafeText.clean() |> retain_text(@prompt_limit),
      attachments: context |> attachments() |> retain(20),
      assistant: "",
      tools: %{},
      tool_order: [],
      reviews: [],
      outcome: nil,
      changes: [],
      events: [],
      seen_events: MapSet.new(),
      status: :starting
    }
  end

  @spec put_request(t(), term()) :: t()
  def put_request(%__MODULE__{} = turn, request) do
    %{turn | request_id: request_id(request), status: :running}
  end

  @spec put_changes(t(), [map()]) :: t()
  def put_changes(%__MODULE__{} = turn, changes) do
    %{turn | changes: changes |> normalize_records() |> retain(@record_limit)}
  end

  @spec put_reviews(t(), [term()]) :: t()
  def put_reviews(%__MODULE__{} = turn, reviews) when is_list(reviews) do
    reviews = reviews |> Enum.reduce(turn.reviews, &put_record(&2, normalize_review(&1))) |> retain(@record_limit)
    %{turn | reviews: reviews, status: :review}
  end

  @spec decide_review(t(), term(), :approve | :deny) :: t()
  def decide_review(%__MODULE__{} = turn, review, decision) when decision in [:approve, :deny] do
    id = review_id(review)

    reviews =
      Enum.map(turn.reviews, fn record ->
        if Map.get(record, :id) == id do
          record
          |> Map.put(:decision, decision)
          |> Map.put(:status, if(decision == :approve, do: :approved, else: :denied))
        else
          record
        end
      end)

    %{turn | reviews: reviews, outcome: nil, status: :running}
  end

  @spec resume(t()) :: t()
  def resume(%__MODULE__{} = turn), do: %{turn | outcome: nil, status: :running}

  @spec fail_review(t(), term()) :: t()
  def fail_review(%__MODULE__{} = turn, error) do
    summary = SafeText.summary(error)
    status = if String.contains?(String.downcase(summary), "expired"), do: :expired, else: :failed

    reviews =
      turn.reviews
      |> Enum.reverse()
      |> update_decided_review(status, summary)
      |> Enum.reverse()

    %{turn | reviews: reviews}
  end

  @spec apply_event(t(), map()) :: {:ok, t()} | {:ignore, atom()}
  def apply_event(%__MODULE__{request_id: request_id}, %{request_id: other})
      when not is_nil(request_id) and not is_nil(other) and request_id != other,
      do: {:ignore, :stale_request}

  def apply_event(%__MODULE__{} = turn, projection) when is_map(projection) do
    cond do
      MapSet.member?(turn.seen_events, projection.id) ->
        {:ignore, :duplicate}

      is_integer(turn.last_seq) and projection.seq <= turn.last_seq ->
        {:ignore, :out_of_order}

      turn.outcome != nil ->
        {:ignore, :terminal_turn}

      true ->
        turn =
          turn
          |> apply_projection(projection)
          |> record_event(projection)

        {:ok, turn}
    end
  end

  @doc "Applies safe, portable Jidoka stream projections to one live turn."
  @spec apply_stream(t(), [map()]) :: t()
  def apply_stream(%__MODULE__{} = turn, projections) when is_list(projections) do
    projections
    |> Enum.with_index()
    |> Enum.reduce(turn, fn {projection, index}, turn ->
      projection = normalize_stream_projection(projection, turn, index)

      with {:ok, timeline_event} <- timeline_event(projection),
           {:ok, turn} <- apply_event(turn, timeline_event) do
        turn
      else
        {:ignore, _reason} -> turn
      end
    end)
  end

  def apply_stream(%__MODULE__{} = turn, _projections), do: turn

  @doc "Restores safe tool identities from one durable assistant message."
  @spec restore_tool_calls(t(), [map()]) :: t()
  def restore_tool_calls(%__MODULE__{} = turn, calls) when is_list(calls) do
    calls
    |> Enum.with_index()
    |> Enum.reduce(turn, fn {call, index}, turn -> restore_tool_call(turn, call, index) end)
  end

  def restore_tool_calls(%__MODULE__{} = turn, _calls), do: turn

  @doc "Marks one durable tool-result identity complete without retaining its result."
  @spec restore_tool_result(t(), map()) :: t()
  def restore_tool_result(%__MODULE__{} = turn, message) when is_map(message) do
    tool_call_id = map_get(message, :tool_call_id)
    operation = map_get(message, :operation)

    case restored_tool_id(turn, tool_call_id, operation) do
      nil ->
        restore_completed_tool(turn, operation)

      id ->
        update_tool_status(turn, id, :completed)
    end
  end

  def restore_tool_result(%__MODULE__{} = turn, _message), do: turn

  @spec finish(t(), atom(), String.t() | nil, keyword()) :: t()
  def finish(%__MODULE__{} = turn, outcome, content, opts \\ []) do
    assistant =
      if is_binary(content) and content != "",
        do: content |> SafeText.clean() |> retain_text(@assistant_limit),
        else: turn.assistant

    %{
      turn
      | assistant: assistant,
        tools: finalize_tools(turn.tools, outcome),
        reviews: opts |> Keyword.get(:reviews, turn.reviews) |> normalize_records() |> retain(@record_limit),
        changes: opts |> Keyword.get(:changes, turn.changes) |> normalize_records() |> retain(@record_limit),
        outcome: %{
          status: outcome,
          error: safe_optional(Keyword.get(opts, :error))
        },
        status: :finished
    }
  end

  defp apply_projection(turn, %{kind: :assistant_delta, data: %{text: text}}) do
    %{turn | assistant: retain_text(turn.assistant <> text, @assistant_limit)}
  end

  defp apply_projection(turn, %{kind: :tool, data: data} = projection) do
    id = data.id

    event = %{
      seq: projection.seq,
      event: projection.event,
      status: data.status,
      summary: data.summary,
      error: data.error
    }

    tool =
      case Map.get(turn.tools, id) do
        nil ->
          %Tool{
            id: id,
            operation: data.operation,
            status: data.status,
            events: [event],
            summary: data.summary,
            error: data.error,
            loop_index: data.loop_index
          }

        %Tool{} = tool ->
          %{
            tool
            | operation: data.operation || tool.operation,
              status: data.status,
              events: retain(tool.events ++ [event], @tool_event_limit),
              summary: data.summary || tool.summary,
              error: data.error || tool.error,
              loop_index: data.loop_index || tool.loop_index
          }
      end

    order = if Map.has_key?(turn.tools, id), do: turn.tool_order, else: turn.tool_order ++ [id]
    {tools, order} = retain_tools(Map.put(turn.tools, id, tool), order)
    %{turn | tools: tools, tool_order: order}
  end

  defp apply_projection(turn, %{kind: :review, data: data}) do
    reviews = turn.reviews |> put_record(normalize_record(data)) |> retain(@record_limit)
    %{turn | reviews: reviews}
  end

  defp apply_projection(turn, %{kind: :outcome, data: data}) do
    %{turn | outcome: normalize_record(data), status: :terminal}
  end

  defp apply_projection(turn, _projection), do: turn

  defp timeline_event(projection) when is_map(projection) do
    request_id = map_get(projection, :request_id)
    sequence = map_get(projection, :seq)
    event = map_get(projection, :event)

    if is_binary(request_id) and is_integer(sequence) and is_binary(event) do
      timeline_event(projection, request_id, sequence, event)
    else
      {:ignore, :invalid_projection}
    end
  end

  defp timeline_event(_projection), do: {:ignore, :invalid_projection}

  defp timeline_event(projection, request_id, sequence, "llm_delta") do
    case assistant_delta(map_get(projection, :data, %{})) do
      "" ->
        {:ignore, :non_content_delta}

      text ->
        {:ok,
         %{
           id: timeline_event_id(projection, request_id, sequence, "llm_delta"),
           request_id: request_id,
           seq: sequence,
           event: "llm_delta",
           kind: :assistant_delta,
           data: %{text: text}
         }}
    end
  end

  defp timeline_event(projection, request_id, sequence, event)
       when event in ~w(effect_planned effect_started effect_replayed effect_completed effect_failed) do
    if map_get(projection, :effect_kind) == "operation" do
      operation = safe_operation(map_get(projection, :operation))
      effect_id = map_get(projection, :effect_id) || {:operation, map_get(projection, :loop_index), operation}

      {:ok,
       %{
         id: timeline_event_id(projection, request_id, sequence, event),
         request_id: request_id,
         seq: sequence,
         event: event,
         kind: :tool,
         data: %{
           id: effect_id,
           operation: operation,
           status: tool_status(event),
           summary: nil,
           error: nil,
           loop_index: map_get(projection, :loop_index)
         }
       }}
    else
      {:ignore, :non_operation_effect}
    end
  end

  defp timeline_event(_projection, _request_id, _sequence, _event), do: {:ignore, :unrendered_event}

  defp normalize_stream_projection(projection, turn, index) when is_map(projection) do
    projection
    |> put_missing(:request_id, turn.request_id)
    |> put_missing(:seq, index)
    |> put_legacy_delta_event()
  end

  defp normalize_stream_projection(projection, _turn, _index), do: projection

  defp put_legacy_delta_event(projection) do
    if is_nil(map_get(projection, :event)) and assistant_delta(map_get(projection, :data, %{})) != "",
      do: Map.put(projection, :event, "llm_delta"),
      else: projection
  end

  defp put_missing(map, key, value) do
    if is_nil(map_get(map, key)) and not is_nil(value), do: Map.put(map, key, value), else: map
  end

  defp timeline_event_id(projection, request_id, sequence, event) do
    {request_id, sequence, event, map_get(projection, :effect_id)}
  end

  defp assistant_delta(data) when is_map(data) do
    chunk_type = map_get(data, :chunk_type)
    type = map_get(data, :type)

    if chunk_type in [nil, "content"] and type not in ["reasoning_delta", "thinking"] do
      [:text, :delta, :content]
      |> Enum.find_value("", fn key ->
        case map_get(data, key) do
          value when is_binary(value) -> value
          _other -> nil
        end
      end)
      |> SafeText.clean()
    else
      ""
    end
  end

  defp assistant_delta(_data), do: ""

  defp tool_status("effect_planned"), do: :planned
  defp tool_status("effect_started"), do: :running
  defp tool_status("effect_replayed"), do: :replayed
  defp tool_status("effect_completed"), do: :completed
  defp tool_status("effect_failed"), do: :failed

  defp safe_operation(operation) when is_binary(operation), do: SafeText.summary(operation)
  defp safe_operation(_operation), do: nil

  defp record_event(turn, projection) do
    event = %{id: projection.id, seq: projection.seq, event: projection.event, kind: projection.kind}
    events = retain(turn.events ++ [event], @event_limit)

    %{
      turn
      | last_seq: projection.seq,
        seen_events: MapSet.new(events, & &1.id),
        events: events
    }
  end

  defp restore_tool_call(turn, call, index) when is_map(call) do
    operation = safe_operation(map_get(call, :name, map_get(call, :operation)))

    if is_binary(operation) and operation != "" do
      id = map_get(call, :provider_call_id, map_get(call, :id)) || {:transcript, turn.id, index}

      tool = %Tool{
        id: id,
        operation: operation,
        status: :planned,
        events: [],
        summary: nil,
        error: nil,
        loop_index: nil
      }

      put_restored_tool(turn, tool)
    else
      turn
    end
  end

  defp restore_tool_call(turn, _call, _index), do: turn

  defp put_restored_tool(turn, %Tool{id: id} = tool) do
    order = if Map.has_key?(turn.tools, id), do: turn.tool_order, else: turn.tool_order ++ [id]
    {tools, order} = retain_tools(Map.put(turn.tools, id, tool), order)
    %{turn | tools: tools, tool_order: order}
  end

  defp restored_tool_id(turn, tool_call_id, _operation)
       when not is_nil(tool_call_id) and is_map_key(turn.tools, tool_call_id),
       do: tool_call_id

  defp restored_tool_id(turn, _tool_call_id, operation) when is_binary(operation) do
    Enum.find(turn.tool_order, fn id ->
      tool = Map.fetch!(turn.tools, id)
      tool.operation == operation and tool.status in [:planned, :running]
    end)
  end

  defp restored_tool_id(_turn, _tool_call_id, _operation), do: nil

  defp restore_completed_tool(turn, operation) when is_binary(operation) and operation != "" do
    index = length(turn.tool_order)

    put_restored_tool(turn, %Tool{
      id: {:transcript_result, turn.id, index},
      operation: SafeText.summary(operation),
      status: :completed,
      events: [],
      summary: nil,
      error: nil,
      loop_index: nil
    })
  end

  defp restore_completed_tool(turn, _operation), do: turn

  defp update_tool_status(turn, id, status) do
    %{turn | tools: Map.update!(turn.tools, id, &%{&1 | status: status})}
  end

  defp finalize_tools(tools, outcome) do
    Map.new(tools, fn {id, tool} -> {id, finalize_tool(tool, outcome)} end)
  end

  defp finalize_tool(%Tool{status: status} = tool, outcome) when status in [:planned, :running] do
    status =
      case outcome do
        :completed -> :completed
        :cancelled -> :cancelled
        :interrupted -> :cancelled
        :failed -> :failed
        _other -> status
      end

    %{tool | status: status}
  end

  defp finalize_tool(%Tool{} = tool, _outcome), do: tool

  defp attachments(context) do
    context
    |> coding_context()
    |> Map.get("files", [])
    |> Enum.map(fn file ->
      file
      |> Map.take(["path", "sha256", "size", "truncated", "ignore"])
      |> normalize_record()
    end)
  end

  defp coding_context(context) when is_map(context) do
    Map.get(context, "coding", Map.get(context, :coding, %{}))
  end

  defp coding_context(_context), do: %{}

  defp request_id(%{request_id: request_id}) when is_binary(request_id), do: request_id
  defp request_id(_request), do: nil

  defp normalize_records(records) when is_list(records), do: Enum.map(records, &normalize_record/1)
  defp normalize_records(_records), do: []

  defp normalize_record(%_{} = record), do: record |> Map.from_struct() |> normalize_record()

  defp normalize_record(record) when is_map(record) do
    Map.new(record, fn {key, value} -> {key, normalize_value(value)} end)
  end

  defp normalize_record(value), do: %{summary: SafeText.summary(value)}

  defp normalize_review(%_{} = review), do: review |> Map.from_struct() |> normalize_review()

  defp normalize_review(review) when is_map(review) do
    id = review_id(review)
    arguments = Map.get(review, :arguments, Map.get(review, "arguments")) || %{}
    arguments_summary = arguments |> normalize_value() |> SafeText.summary()

    review
    |> Map.take([
      :interrupt_id,
      :operation,
      :reason,
      :created_at_ms,
      :expires_at_ms,
      "interrupt_id",
      "operation",
      "reason",
      "created_at_ms",
      "expires_at_ms"
    ])
    |> normalize_record()
    |> Map.put(:id, id)
    |> Map.put(:arguments_summary, arguments_summary)
    |> Map.put(:status, :pending)
  end

  defp normalize_review(review), do: %{id: review_id(review), summary: SafeText.summary(review), status: :pending}

  defp normalize_value(value) when is_binary(value), do: SafeText.clean(value)
  defp normalize_value(value) when is_map(value), do: normalize_record(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp put_record(records, %{id: id} = record) do
    case Enum.find_index(records, &(Map.get(&1, :id) == id)) do
      nil -> records ++ [record]
      index -> List.replace_at(records, index, Map.merge(Enum.at(records, index), record))
    end
  end

  defp put_record(records, record), do: records ++ [record]

  defp review_id(%{interrupt_id: id}), do: id
  defp review_id(%{"interrupt_id" => id}), do: id
  defp review_id(%{id: id}), do: id
  defp review_id(%{"id" => id}), do: id
  defp review_id(review), do: {:review, SafeText.summary(review)}

  defp update_decided_review([%{status: status} = review | reviews], failed_status, summary)
       when status in [:approved, :denied] do
    [review |> Map.put(:status, failed_status) |> Map.put(:error, summary) | reviews]
  end

  defp update_decided_review([review | reviews], failed_status, summary),
    do: [review | update_decided_review(reviews, failed_status, summary)]

  defp update_decided_review([], _failed_status, _summary), do: []

  defp retain_tools(tools, order) when length(order) > @tool_limit do
    order = Enum.take(order, -@tool_limit)
    {Map.take(tools, order), order}
  end

  defp retain_tools(tools, order), do: {tools, order}

  defp retain(values, limit) when length(values) > limit, do: Enum.take(values, -limit)
  defp retain(values, _limit), do: values

  defp retain_text(text, limit) do
    if String.length(text) > limit, do: "…\n" <> String.slice(text, -limit, limit), else: text
  end

  defp safe_optional(nil), do: nil
  defp safe_optional(value), do: SafeText.summary(value)

  defp map_get(map, key, default \\ nil)
  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
