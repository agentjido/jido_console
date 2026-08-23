defmodule Jido.Console.Session.Command do
  @moduledoc "One validated command for a Console thread owner."

  alias Jido.Console.Digest
  alias Jido.Console.Models.Commands, as: ModelCommands
  alias Jido.Console.Session.Queue

  @types [:submit, :cancel, :approve, :deny, :remove, :select_model, :status, :history, :stop]

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
         {:ok, %__MODULE__{} = command} <- Zoi.parse(@schema, attrs),
         :ok <- validate_shape(command) do
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

  defp validate_shape(%__MODULE__{type: :submit, text: text, queue_item_id: id, request_id: request_id})
       when is_binary(text) and text != "" and is_binary(id) and is_binary(request_id),
       do: :ok

  defp validate_shape(%__MODULE__{type: :cancel, request_id: request_id}) when is_binary(request_id), do: :ok

  defp validate_shape(%__MODULE__{type: type, request_id: request_id, review_id: review_id})
       when type in [:approve, :deny] and is_binary(request_id) and is_binary(review_id),
       do: :ok

  defp validate_shape(%__MODULE__{type: :remove, queue_item_id: id}) when is_binary(id), do: :ok

  defp validate_shape(%__MODULE__{type: :select_model, text: identity}) when is_binary(identity) do
    case ModelCommands.parse_identity(identity) do
      {:ok, _provider, _model} -> :ok
      {:error, _reason} -> {:error, :invalid_command_shape}
    end
  end

  defp validate_shape(%__MODULE__{type: type}) when type in [:status, :history, :stop], do: :ok
  defp validate_shape(_command), do: {:error, :invalid_command_shape}
end
