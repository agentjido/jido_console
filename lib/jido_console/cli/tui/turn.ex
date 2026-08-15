defmodule Jido.Console.Tui.Turn do
  @moduledoc false

  alias Jido.Console.Tui.{EventProjection, SafeText}

  @assistant_limit 200_000
  @prompt_limit 65_536
  @event_limit 1_000
  @tool_limit 200
  @tool_event_limit 100
  @record_limit 100

  defmodule Tool do
    @moduledoc false
    @enforce_keys [:id, :operation, :status, :events]
    defstruct @enforce_keys ++ [:summary, :error, :loop_index]

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

  @enforce_keys [
    :id,
    :prompt,
    :attachments,
    :assistant,
    :tools,
    :tool_order,
    :reviews,
    :outcome,
    :changes,
    :events,
    :seen_events,
    :status
  ]
  defstruct @enforce_keys ++ [request_id: nil, last_seq: nil]

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

  @spec apply_event(t(), EventProjection.t()) :: {:ok, t()} | {:ignore, atom()}
  def apply_event(%__MODULE__{request_id: request_id}, %EventProjection{request_id: other})
      when request_id != other,
      do: {:ignore, :stale_request}

  def apply_event(%__MODULE__{} = turn, %EventProjection{} = projection) do
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

  @spec finish(t(), atom(), String.t() | nil, keyword()) :: t()
  def finish(%__MODULE__{} = turn, outcome, content, opts \\ []) do
    assistant =
      if is_binary(content) and content != "",
        do: content |> SafeText.clean() |> retain_text(@assistant_limit),
        else: turn.assistant

    %{
      turn
      | assistant: assistant,
        reviews: opts |> Keyword.get(:reviews, turn.reviews) |> normalize_records() |> retain(@record_limit),
        changes: opts |> Keyword.get(:changes, turn.changes) |> normalize_records() |> retain(@record_limit),
        outcome: %{
          status: outcome,
          error: safe_optional(Keyword.get(opts, :error))
        },
        status: :finished
    }
  end

  defp apply_projection(turn, %EventProjection{kind: :assistant_delta, data: %{text: text}}) do
    %{turn | assistant: retain_text(turn.assistant <> text, @assistant_limit)}
  end

  defp apply_projection(turn, %EventProjection{kind: :tool, data: data} = projection) do
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
              summary: data.summary,
              error: data.error || tool.error,
              loop_index: data.loop_index || tool.loop_index
          }
      end

    order = if Map.has_key?(turn.tools, id), do: turn.tool_order, else: turn.tool_order ++ [id]
    {tools, order} = retain_tools(Map.put(turn.tools, id, tool), order)
    %{turn | tools: tools, tool_order: order}
  end

  defp apply_projection(turn, %EventProjection{kind: :review, data: data}) do
    reviews = turn.reviews |> put_record(normalize_record(data)) |> retain(@record_limit)
    %{turn | reviews: reviews}
  end

  defp apply_projection(turn, %EventProjection{kind: :outcome, data: data}) do
    %{turn | outcome: normalize_record(data), status: :terminal}
  end

  defp apply_projection(turn, %EventProjection{}), do: turn

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
end
