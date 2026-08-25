defmodule Jido.Console.Session.Client.JSON.Protocol do
  @moduledoc "Validates and translates the experimental JSONL protocol."

  alias Jido.Console.Error
  alias Jido.Console.Session.{Command, Event, View}

  @version 1
  @default_max_bytes 1_048_576
  @default_history_limit 200

  @non_empty_string Zoi.string() |> Zoi.min(1)
  @base_input %{
    "version" => Zoi.literal(@version),
    "id" => @non_empty_string,
    "thread_id" => @non_empty_string
  }

  @input_schemas %{
    "attach" => Zoi.map(Map.put(@base_input, "type", Zoi.literal("attach")), unrecognized_keys: :error),
    "reattach" => Zoi.map(Map.put(@base_input, "type", Zoi.literal("reattach")), unrecognized_keys: :error),
    "detach" => Zoi.map(Map.put(@base_input, "type", Zoi.literal("detach")), unrecognized_keys: :error),
    "submit" =>
      Zoi.map(
        Map.merge(@base_input, %{
          "type" => Zoi.literal("submit"),
          "request_id" => @non_empty_string,
          "text" => @non_empty_string,
          "context" => Zoi.map() |> Zoi.optional() |> Zoi.default(%{})
        }),
        unrecognized_keys: :error
      ),
    "cancel" =>
      Zoi.map(
        Map.merge(@base_input, %{
          "type" => Zoi.literal("cancel"),
          "request_id" => @non_empty_string
        }),
        unrecognized_keys: :error
      ),
    "approve" =>
      Zoi.map(
        Map.merge(@base_input, %{
          "type" => Zoi.literal("approve"),
          "request_id" => @non_empty_string,
          "review_id" => @non_empty_string
        }),
        unrecognized_keys: :error
      ),
    "deny" =>
      Zoi.map(
        Map.merge(@base_input, %{
          "type" => Zoi.literal("deny"),
          "request_id" => @non_empty_string,
          "review_id" => @non_empty_string
        }),
        unrecognized_keys: :error
      ),
    "remove" =>
      Zoi.map(
        Map.merge(@base_input, %{
          "type" => Zoi.literal("remove"),
          "queue_item_id" => @non_empty_string
        }),
        unrecognized_keys: :error
      ),
    "select_model" =>
      Zoi.map(
        Map.merge(@base_input, %{
          "type" => Zoi.literal("select_model"),
          "identity" => @non_empty_string
        }),
        unrecognized_keys: :error
      ),
    "status" => Zoi.map(Map.put(@base_input, "type", Zoi.literal("status")), unrecognized_keys: :error),
    "history" =>
      Zoi.map(
        Map.merge(@base_input, %{
          "type" => Zoi.literal("history"),
          "limit" =>
            Zoi.integer()
            |> Zoi.positive()
            |> Zoi.max(1000)
            |> Zoi.optional()
            |> Zoi.default(@default_history_limit),
          "before_sequence" => Zoi.integer() |> Zoi.positive() |> Zoi.optional()
        }),
        unrecognized_keys: :error
      ),
    "stop" => Zoi.map(Map.put(@base_input, "type", Zoi.literal("stop")), unrecognized_keys: :error)
  }

  @nullable_string Zoi.string() |> Zoi.nullish()
  @optional_json Zoi.json() |> Zoi.optional()
  @output_schemas %{
    "result" =>
      Zoi.map(
        %{
          "version" => Zoi.literal(@version),
          "type" => Zoi.literal("result"),
          "id" => @nullable_string,
          "thread_id" => @nullable_string,
          "ok" => Zoi.boolean(),
          "data" => @optional_json,
          "error" => @optional_json
        },
        unrecognized_keys: :error
      ),
    "view" =>
      Zoi.map(
        %{
          "version" => Zoi.literal(@version),
          "type" => Zoi.literal("view"),
          "thread_id" => @non_empty_string,
          "attachment_id" => @non_empty_string,
          "view" => Zoi.json()
        },
        unrecognized_keys: :error
      ),
    "gap" =>
      Zoi.map(
        %{
          "version" => Zoi.literal(@version),
          "type" => Zoi.literal("gap"),
          "thread_id" => @non_empty_string,
          "attachment_id" => @non_empty_string,
          "from_revision" => Zoi.integer() |> Zoi.gte(0),
          "through_revision" => Zoi.integer() |> Zoi.gte(0)
        },
        unrecognized_keys: :error
      ),
    "lifecycle" =>
      Zoi.map(
        %{
          "version" => Zoi.literal(@version),
          "type" => Zoi.literal("lifecycle"),
          "event" => Zoi.enum(["reattaching", "reattached", "detached"]),
          "thread_id" => @non_empty_string,
          "attachment_id" => @nullable_string,
          "previous_attachment_id" => @nullable_string,
          "reason" => @optional_json
        },
        unrecognized_keys: :error
      ),
    "fatal" =>
      Zoi.map(
        %{
          "version" => Zoi.literal(@version),
          "type" => Zoi.literal("fatal"),
          "error" => Zoi.json()
        },
        unrecognized_keys: :error
      )
  }

  @doc "Returns the experimental protocol version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Returns the default input and output record size limit."
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @doc "Decodes and validates one input JSON record."
  @spec decode(binary(), keyword()) :: {:ok, map()} | {:error, term(), map() | nil}
  def decode(line, opts \\ []) when is_binary(line) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    if byte_size(line) <= max_bytes,
      do: decode_json(line),
      else: {:error, {:input_too_large, byte_size(line), max_bytes}, nil}
  end

  @doc "Translates one validated input record to a session command."
  @spec command(map()) :: {:ok, Command.t()} | {:error, term()}
  def command(%{"id" => id, "type" => type, "thread_id" => thread_id} = input) do
    attrs =
      [id: id, type: command_type(type), thread_id: thread_id, payload: %{}]
      |> command_attrs(input)

    Command.new(attrs)
  end

  @doc "Builds a successful correlated result."
  @spec success(map() | nil, term()) :: map()
  def success(input, data), do: build_result(input, true, "data", data)

  @doc "Builds a failed correlated result with a redacted error."
  @spec failure(map() | nil, term()) :: map()
  def failure(input, reason), do: build_result(input, false, "error", error(reason))

  @doc "Builds one complete portable view record."
  @spec view(String.t(), String.t(), View.t()) :: map()
  def view(thread_id, attachment_id, %View{} = view) do
    %{
      "version" => @version,
      "type" => "view",
      "thread_id" => thread_id,
      "attachment_id" => attachment_id,
      "view" => portable!(view)
    }
  end

  @doc "Builds one skipped-revision record."
  @spec gap(String.t(), String.t(), non_neg_integer(), non_neg_integer()) :: map()
  def gap(thread_id, attachment_id, first, last) do
    %{
      "version" => @version,
      "type" => "gap",
      "thread_id" => thread_id,
      "attachment_id" => attachment_id,
      "from_revision" => first,
      "through_revision" => last
    }
  end

  @doc "Builds one attachment lifecycle record."
  @spec lifecycle(String.t(), String.t(), String.t() | nil, String.t() | nil, term() | nil) :: map()
  def lifecycle(event, thread_id, attachment_id, previous_attachment_id, reason \\ nil) do
    %{
      "version" => @version,
      "type" => "lifecycle",
      "event" => event,
      "thread_id" => thread_id,
      "attachment_id" => attachment_id,
      "previous_attachment_id" => previous_attachment_id
    }
    |> maybe_put("reason", if(is_nil(reason), do: nil, else: error(reason)))
  end

  @doc "Builds one stream-level failure record."
  @spec fatal(term()) :: map()
  def fatal(reason), do: %{"version" => @version, "type" => "fatal", "error" => error(reason)}

  @doc "Normalizes and redacts a protocol error."
  @spec error(term()) :: map()
  def error(reason) do
    normalized = reason |> Error.to_map() |> portable!()

    normalized
    |> Map.put("code", error_code(reason, normalized))
    |> stringify_category()
  end

  @doc "Validates and encodes one output record with a trailing newline."
  @spec encode(map(), keyword()) :: {:ok, iodata()} | {:error, term()}
  def encode(record, opts \\ []) when is_map(record) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    with {:ok, portable} <- portable(record),
         {:ok, validated} <- validate_output(portable),
         {:ok, encoded} <- Jason.encode_to_iodata(validated) do
      size = IO.iodata_length(encoded)
      if size <= max_bytes, do: {:ok, [encoded, ?\n]}, else: {:error, {:output_too_large, size, max_bytes}}
    end
  end

  @doc "Converts one value to JSON-safe Elixir data."
  @spec portable(term()) :: {:ok, term()} | {:error, term()}
  def portable(value) when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
    do: {:ok, value}

  def portable(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  def portable(values) when is_list(values), do: reduce_portable(values, [])
  def portable(%View{} = view), do: portable(Map.from_struct(view))
  def portable(%Event{} = event), do: portable(Event.to_view(event))
  def portable(%_{}), do: {:error, {:forbidden_runtime_value, :struct}}

  def portable(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, result} ->
      with {:ok, key} <- portable_key(key),
           {:ok, item} <- portable(item) do
        {:cont, {:ok, Map.put(result, key, item)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def portable(value) when is_tuple(value), do: value |> Tuple.to_list() |> portable()
  def portable(value) when is_pid(value), do: {:error, {:forbidden_runtime_value, :pid}}
  def portable(value) when is_reference(value), do: {:error, {:forbidden_runtime_value, :reference}}
  def portable(value) when is_port(value), do: {:error, {:forbidden_runtime_value, :port}}
  def portable(value) when is_function(value), do: {:error, {:forbidden_runtime_value, :function}}
  def portable(_value), do: {:error, :non_json_value}

  defp decode_json(line) do
    case Jason.decode(line) do
      {:ok, %{} = input} -> validate_input(input)
      {:ok, _value} -> {:error, :invalid_json_record, nil}
      {:error, reason} -> {:error, {:invalid_json, reason}, nil}
    end
  end

  defp validate_input(%{"type" => type} = input) when is_binary(type) do
    case Map.fetch(@input_schemas, type) do
      {:ok, schema} ->
        case Zoi.parse(schema, input) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, errors} -> {:error, {:invalid_json_command, Zoi.treefy_errors(errors)}, input_identity(input)}
        end

      :error ->
        {:error, {:unknown_json_command, type}, input_identity(input)}
    end
  end

  defp validate_input(input), do: {:error, :invalid_json_command, input_identity(input)}

  defp validate_output(%{"type" => type} = record) do
    with {:ok, schema} <- Map.fetch(@output_schemas, type),
         {:ok, validated} <- Zoi.parse(schema, record) do
      {:ok, validated}
    else
      :error -> {:error, :invalid_json_output_type}
      {:error, errors} -> {:error, {:invalid_json_output, Zoi.treefy_errors(errors)}}
    end
  end

  defp validate_output(_record), do: {:error, :invalid_json_output_type}

  defp command_type("submit"), do: :submit
  defp command_type("cancel"), do: :cancel
  defp command_type("approve"), do: :approve
  defp command_type("deny"), do: :deny
  defp command_type("remove"), do: :remove
  defp command_type("select_model"), do: :select_model
  defp command_type("status"), do: :status
  defp command_type("history"), do: :history
  defp command_type("stop"), do: :stop

  defp command_attrs(attrs, %{"type" => "submit"} = input) do
    Keyword.merge(attrs,
      queue_item_id: input["id"],
      request_id: input["request_id"],
      text: input["text"],
      payload: %{"context" => input["context"]}
    )
  end

  defp command_attrs(attrs, %{"type" => "cancel"} = input),
    do: Keyword.put(attrs, :request_id, input["request_id"])

  defp command_attrs(attrs, %{"type" => type} = input) when type in ["approve", "deny"] do
    Keyword.merge(attrs, request_id: input["request_id"], review_id: input["review_id"])
  end

  defp command_attrs(attrs, %{"type" => "remove"} = input),
    do: Keyword.put(attrs, :queue_item_id, input["queue_item_id"])

  defp command_attrs(attrs, %{"type" => "select_model"} = input),
    do: Keyword.put(attrs, :text, input["identity"])

  defp command_attrs(attrs, %{"type" => "history"} = input) do
    payload = maybe_put(%{"limit" => input["limit"]}, "before_sequence", input["before_sequence"])
    Keyword.put(attrs, :payload, payload)
  end

  defp command_attrs(attrs, _input), do: attrs

  defp build_result(input, ok, key, value) do
    %{
      "version" => @version,
      "type" => "result",
      "id" => input_value(input, "id"),
      "thread_id" => input_value(input, "thread_id"),
      "ok" => ok,
      key => portable!(value)
    }
  end

  defp input_identity(input),
    do: %{"id" => input_value(input, "id"), "thread_id" => input_value(input, "thread_id")}

  defp input_value(%{} = input, key) do
    case Map.get(input, key) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp input_value(_input, _key), do: nil

  defp portable!(value) do
    case portable(value) do
      {:ok, portable} -> portable
      {:error, reason} -> raise ArgumentError, "invalid JSON protocol value: #{inspect(reason)}"
    end
  end

  defp portable_key(key) when is_binary(key), do: {:ok, key}
  defp portable_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp portable_key(_key), do: {:error, :non_string_json_key}

  defp reduce_portable([], result), do: {:ok, Enum.reverse(result)}

  defp reduce_portable([value | values], result) do
    case portable(value) do
      {:ok, portable} -> reduce_portable(values, [portable | result])
      {:error, reason} -> {:error, reason}
    end
  end

  defp error_code(reason, _normalized) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({code, _rest}, _normalized) when is_atom(code), do: Atom.to_string(code)
  defp error_code({code, _one, _two}, _normalized) when is_atom(code), do: Atom.to_string(code)
  defp error_code(_reason, %{"category" => category}) when is_binary(category), do: category <> "_error"
  defp error_code(_reason, _normalized), do: "internal_error"

  defp stringify_category(%{"category" => category} = error) when is_atom(category),
    do: %{error | "category" => Atom.to_string(category)}

  defp stringify_category(error), do: error

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
