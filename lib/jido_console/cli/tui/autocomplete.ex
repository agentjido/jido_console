defmodule Jido.Console.Tui.Autocomplete do
  @moduledoc """
  Pure, client-local slash-command and model completion.

  Completion results are advisory. This module does not parse submitted commands,
  change a selection, or contact a session owner.
  """

  alias Jido.Console.Tui.{Command, Selection}

  @contexts [:inactive, :command, :model, :no_match]

  @schema Zoi.struct(
            __MODULE__,
            %{
              context: Zoi.enum(@contexts) |> Zoi.default(:inactive),
              candidates: Zoi.array(Zoi.map()) |> Zoi.default([]),
              focused_identity: Zoi.string() |> Zoi.nullish(),
              selected_index: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
              completion: Zoi.string() |> Zoi.nullish()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type context :: :inactive | :command | :model | :no_match
  @type candidate :: map()
  @type t :: unquote(Zoi.type_spec(@schema))

  @doc "Returns the autocomplete schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Derives completion state from editor text, cursor, and local selection data."
  @spec derive(String.t(), non_neg_integer(), Selection.t() | map(), String.t() | nil) :: t()
  def derive(input, cursor, selection, focused_identity \\ nil)

  def derive(input, cursor, selection, focused_identity)
      when is_binary(input) and is_integer(cursor) and cursor >= 0 do
    if eligible_input?(input, cursor) do
      derive_context(input, selection, focused_identity)
    else
      inactive()
    end
  end

  def derive(_input, _cursor, _selection, _focused_identity), do: inactive()

  @doc "Moves focus by one row and clamps it to the selectable candidate list."
  @spec move(t(), :up | :down) :: t()
  def move(%__MODULE__{selected_index: index, candidates: candidates} = state, direction)
      when is_integer(index) and direction in [:up, :down] do
    selectable = Enum.filter(candidates, &Map.get(&1, :selectable?, false))

    case selectable do
      [] ->
        state

      _models ->
        focus_at(state, selectable, clamp_index(index + direction_delta(direction), length(selectable)))
    end
  end

  def move(%__MODULE__{} = state, direction) when direction in [:up, :down], do: state

  @doc "Returns at most capacity rows and keeps the selected candidate in the slice."
  @spec visible_slice(t(), non_neg_integer()) :: %{
          rows: [candidate()],
          offset: non_neg_integer(),
          selected_index: non_neg_integer() | nil,
          interactive?: boolean()
        }
  def visible_slice(%__MODULE__{} = state, capacity) when is_integer(capacity) and capacity > 0 do
    row_count = length(state.candidates)
    offset = visible_offset(state.selected_index, row_count, capacity)
    rows = Enum.slice(state.candidates, offset, capacity)

    selected_index =
      case state.selected_index do
        index when is_integer(index) and index >= offset and index < offset + length(rows) ->
          index - offset

        _other ->
          nil
      end

    %{
      rows: rows,
      offset: offset,
      selected_index: selected_index,
      interactive?: interactive_row?(rows, selected_index)
    }
  end

  def visible_slice(%__MODULE__{}, _capacity),
    do: %{rows: [], offset: 0, selected_index: nil, interactive?: false}

  defp derive_context(input, selection, focused_identity) do
    case argument_context(input) do
      {:ok, command, leading, prefix} ->
        derive_arguments(command.argument_source, command, leading, prefix, selection, focused_identity)

      :error ->
        derive_commands(input, focused_identity)
    end
  end

  defp derive_arguments(:models, command, leading, prefix, selection, focused_identity),
    do: derive_models(command.name, leading, prefix, selection, focused_identity)

  defp derive_arguments(_source, _command, _leading, _prefix, _selection, _focused_identity),
    do: inactive()

  defp derive_commands(input, focused_identity) do
    case command_context(input) do
      {:ok, leading, prefix} ->
        case command_candidates(leading, prefix) do
          [] -> feedback(:no_match, "No matching commands")
          candidates -> build(:command, candidates, focused_identity)
        end

      :error ->
        inactive()
    end
  end

  defp derive_models(command_name, leading, prefix, selection, focused_identity) do
    case Selection.selectable_models(selection) do
      {:ok, models} ->
        prefix = String.downcase(prefix)

        candidates =
          models
          |> Enum.filter(&model_match?(&1, prefix))
          |> Enum.map(&model_candidate(&1, command_name, leading))

        case candidates do
          [] -> feedback(:no_match, "No matching models")
          candidates -> build(:model, candidates, focused_identity)
        end

      {:error, _reason} ->
        feedback(:invalid_catalog, "Model catalog is unavailable")
    end
  end

  defp command_candidates(leading, prefix) do
    Command.registry()
    |> Enum.filter(&String.starts_with?(&1.name, prefix))
    |> Enum.map(fn command ->
      argument_suffix = if Map.has_key?(command, :argument_source), do: " ", else: ""

      %{
        kind: :command,
        identity: command.name,
        name: command.name,
        usage: command.usage,
        summary: command.summary,
        completion: leading <> "/" <> command.name <> argument_suffix,
        selectable?: true
      }
    end)
  end

  defp model_candidate(model, command_name, leading) do
    %{
      kind: :model,
      identity: model.identity,
      provider: model.provider,
      model: model.model,
      tier: model.tier,
      current?: model.current?,
      completion: leading <> "/" <> command_name <> " " <> model.identity,
      selectable?: true
    }
  end

  defp model_match?(model, prefix) do
    Enum.any?([model.provider, model.model, model.identity], fn field ->
      field |> String.downcase() |> String.starts_with?(prefix)
    end)
  end

  defp build(context, candidates, focused_identity) do
    selected_index = Enum.find_index(candidates, &(&1.identity == focused_identity)) || 0
    selected = Enum.at(candidates, selected_index)

    %__MODULE__{
      context: context,
      candidates: candidates,
      focused_identity: selected.identity,
      selected_index: selected_index,
      completion: selected.completion
    }
  end

  defp feedback(reason, message) do
    %__MODULE__{
      context: :no_match,
      candidates: [
        %{
          kind: :feedback,
          identity: nil,
          reason: reason,
          message: message,
          selectable?: false
        }
      ]
    }
  end

  defp focus_at(state, selectable, index) do
    candidate = Enum.at(selectable, index)

    %{
      state
      | focused_identity: candidate.identity,
        selected_index: index,
        completion: candidate.completion
    }
  end

  defp eligible_input?(input, cursor) do
    String.valid?(input) and cursor == String.length(input) and
      not String.contains?(input, ["\n", "\r"])
  end

  defp argument_context(input) do
    case Regex.run(~r/\A([ \t]*)\/([a-z0-9_-]+)[ \t]+([^ \t]*)\z/u, input, capture: :all_but_first) do
      [leading, name, prefix] ->
        case Enum.find(Command.registry(), &(&1.name == name and Map.has_key?(&1, :argument_source))) do
          nil -> :error
          command -> {:ok, command, leading, prefix}
        end

      _other ->
        :error
    end
  end

  defp command_context(input) do
    case Regex.run(~r/\A([ \t]*)\/([a-z0-9_-]*)\z/u, input, capture: :all_but_first) do
      [leading, prefix] -> {:ok, leading, prefix}
      _other -> :error
    end
  end

  defp visible_offset(nil, _row_count, _capacity), do: 0

  defp visible_offset(selected_index, row_count, capacity) do
    selected_index
    |> Kernel.-(capacity - 1)
    |> max(0)
    |> min(max(row_count - capacity, 0))
  end

  defp interactive_row?(_rows, nil), do: false

  defp interactive_row?(rows, selected_index) do
    case Enum.at(rows, selected_index) do
      row when is_map(row) -> Map.get(row, :selectable?, false)
      _other -> false
    end
  end

  defp direction_delta(:up), do: -1
  defp direction_delta(:down), do: 1
  defp clamp_index(index, count), do: index |> max(0) |> min(count - 1)
  defp inactive, do: %__MODULE__{}
end
