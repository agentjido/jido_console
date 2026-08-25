defmodule Jido.Console.Session.Command do
  @moduledoc "One validated command for a Console thread owner."

  alias Jido.Console.Digest
  alias Jido.Console.Models.Commands, as: ModelCommands
  alias Jido.Console.Session.Queue

  @types [
    :submit,
    :cancel,
    :approve,
    :deny,
    :remove,
    :select_agent,
    :select_model,
    :select_execution_policy,
    :status,
    :history,
    :stop
  ]
  @max_history_limit 1_000

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string() |> Zoi.min(1),
              type: Zoi.enum(@types),
              thread_id: Zoi.string() |> Zoi.min(1),
              queue_item_id: Zoi.string() |> Zoi.min(1) |> Zoi.optional() |> Zoi.default(nil),
              request_id: Zoi.string() |> Zoi.min(1) |> Zoi.optional() |> Zoi.default(nil),
              review_id: Zoi.string() |> Zoi.min(1) |> Zoi.optional() |> Zoi.default(nil),
              text: Zoi.string() |> Zoi.optional() |> Zoi.default(nil),
              payload: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true,
            unrecognized_keys: :error
          )
          |> Zoi.refine({__MODULE__, :validate_shape, []})

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the command schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds and validates one command."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    with true <- is_map(attrs),
         {:ok, %__MODULE__{} = command} <- Zoi.parse(@schema, attrs) do
      {:ok, command}
    else
      false -> {:error, :invalid_command}
      {:error, _reason} -> {:error, :invalid_command}
    end
  end

  @doc "Builds one command and raises when it is invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, command} -> command
      {:error, reason} -> raise ArgumentError, "invalid session command: #{inspect(reason)}"
    end
  end

  @doc false
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = command),
    do: Digest.portable(:erlang.term_to_binary({command.text, command.payload}, [:deterministic]))

  @doc false
  @spec first_lock_digest(t(), String.t()) :: String.t()
  def first_lock_digest(%__MODULE__{} = command, binding_digest) when is_binary(binding_digest) do
    Digest.semantic(:first_prompt_binding_lock, %{
      "thread_id" => command.thread_id,
      "queue_item_id" => command.queue_item_id,
      "request_id" => command.request_id,
      "command_digest" => digest(command),
      "binding_digest" => binding_digest
    })
  end

  @doc false
  @spec lock_operation_id(t()) :: String.t()
  def lock_operation_id(%__MODULE__{} = command) do
    Enum.join([command.thread_id, command.queue_item_id, "binding-lock"], ":")
  end

  @doc false
  @spec item(t(), String.t()) :: map()
  def item(%__MODULE__{} = command, digest) do
    %{
      id: command.queue_item_id,
      request_id: command.request_id,
      text: command.text,
      context: Map.get(command.payload, "context", Map.get(command.payload, :context, %{})),
      digest: digest
    }
  end

  @doc false
  @spec from_item(map(), String.t()) :: t()
  def from_item(item, thread_id) do
    new!(
      id: item.id,
      type: :submit,
      thread_id: thread_id,
      queue_item_id: item.id,
      request_id: item.request_id,
      text: item.text,
      payload: %{"context" => item.context}
    )
  end

  @doc false
  @spec find_item(map(), String.t()) :: map() | nil
  def find_item(state, id) do
    if state.active && state.active.id == id,
      do: state.active,
      else: Enum.find(Queue.to_list(state.queue), &(&1.id == id))
  end

  @doc false
  @spec acceptance(map(), boolean(), map()) :: map()
  def acceptance(item, duplicate, state) do
    %{
      thread_id: state.thread_id,
      queue_item_id: item.id,
      request_id: item.request_id,
      duplicate: duplicate,
      status: if(state.active && state.active.id == item.id, do: state.status, else: :queued)
    }
  end

  @doc false
  @spec validate_shape(t(), Zoi.Context.t()) :: :ok | {:error, String.t()}
  def validate_shape(%__MODULE__{type: :submit} = command, _opts) do
    if present?(command.text) and present?(command.queue_item_id) and present?(command.request_id) and
         is_nil(command.review_id) and valid_submit_payload?(command.payload),
       do: :ok,
       else: invalid_shape()
  end

  def validate_shape(%__MODULE__{type: :cancel} = command, _opts) do
    if present?(command.request_id) and empty_fields?(command, [:queue_item_id, :review_id, :text]) and
         command.payload == %{},
       do: :ok,
       else: invalid_shape()
  end

  def validate_shape(%__MODULE__{type: type} = command, _opts) when type in [:approve, :deny] do
    if present?(command.request_id) and present?(command.review_id) and
         empty_fields?(command, [:queue_item_id, :text]) and command.payload == %{},
       do: :ok,
       else: invalid_shape()
  end

  def validate_shape(%__MODULE__{type: :remove} = command, _opts) do
    if present?(command.queue_item_id) and empty_fields?(command, [:request_id, :review_id, :text]) and
         command.payload == %{},
       do: :ok,
       else: invalid_shape()
  end

  def validate_shape(%__MODULE__{type: :select_model, text: identity} = command, _opts) do
    with true <- present?(identity),
         true <- empty_fields?(command, [:queue_item_id, :request_id, :review_id]),
         true <- valid_selection_payload?(command.payload, false),
         {:ok, _provider, _model} <- ModelCommands.parse_identity(identity) do
      :ok
    else
      _invalid -> invalid_shape()
    end
  end

  def validate_shape(%__MODULE__{type: :select_agent, text: source} = command, _opts) do
    if present?(source) and empty_fields?(command, [:queue_item_id, :request_id, :review_id]) and
         command.payload == %{},
       do: :ok,
       else: invalid_shape()
  end

  def validate_shape(%__MODULE__{type: :select_execution_policy, text: id} = command, _opts) do
    if present?(id) and empty_fields?(command, [:queue_item_id, :request_id, :review_id]) and
         valid_selection_payload?(command.payload, true),
       do: :ok,
       else: invalid_shape()
  end

  def validate_shape(%__MODULE__{type: :history} = command, _opts) do
    if empty_fields?(command, [:queue_item_id, :request_id, :review_id, :text]) and
         valid_history_payload?(command.payload),
       do: :ok,
       else: invalid_shape()
  end

  def validate_shape(%__MODULE__{type: type} = command, _opts) when type in [:status, :stop] do
    if empty_fields?(command, [:queue_item_id, :request_id, :review_id, :text]) and command.payload == %{},
      do: :ok,
      else: invalid_shape()
  end

  def validate_shape(_command, _opts), do: invalid_shape()

  defp present?(value), do: is_binary(value) and value != ""

  defp empty_fields?(command, fields), do: Enum.all?(fields, &(Map.fetch!(command, &1) == nil))

  defp valid_submit_payload?(payload) do
    case Map.to_list(payload) do
      [] -> true
      [{key, context}] when key in [:context, "context"] -> is_map(context)
      _other -> false
    end
  end

  defp valid_history_payload?(payload) do
    keys = Map.keys(payload)

    Enum.all?(keys, &(&1 in [:limit, "limit", :before_sequence, "before_sequence"])) and
      not duplicate_key?(payload, :limit, "limit") and
      not duplicate_key?(payload, :before_sequence, "before_sequence") and
      valid_limit?(field(payload, :limit, "limit")) and
      valid_before_sequence?(field(payload, :before_sequence, "before_sequence"))
  end

  defp duplicate_key?(payload, atom_key, string_key),
    do: Map.has_key?(payload, atom_key) and Map.has_key?(payload, string_key)

  defp field(payload, atom_key, string_key),
    do: Map.get(payload, string_key, Map.get(payload, atom_key))

  defp valid_limit?(nil), do: true
  defp valid_limit?(limit), do: is_integer(limit) and limit > 0 and limit <= @max_history_limit

  defp valid_before_sequence?(nil), do: true
  defp valid_before_sequence?(sequence), do: is_integer(sequence) and sequence > 0

  defp valid_selection_payload?(payload, allow_root?) do
    allowed = if allow_root?, do: [:origin, "origin", :project_root, "project_root"], else: [:origin, "origin"]
    origin = field(payload, :origin, "origin")
    root = field(payload, :project_root, "project_root")

    Enum.all?(Map.keys(payload), &(&1 in allowed)) and
      not duplicate_key?(payload, :origin, "origin") and
      not duplicate_key?(payload, :project_root, "project_root") and
      origin in [nil, :api, :tui, "api", "tui"] and
      (not allow_root? or is_nil(root) or present?(root))
  end

  defp invalid_shape, do: {:error, "invalid command shape"}
end
