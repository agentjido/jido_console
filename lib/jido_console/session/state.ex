defmodule Jido.Console.Session.State do
  @moduledoc """
  Renderer-neutral semantic session state.

  Shared state contains classified Console events. It contains no renderer
  data, process handles, or live runtime values.
  """

  alias Jido.Console.Session.{Envelope, Identity}

  @forbidden_keys MapSet.new(
                    ~w(ansi dom viewport draft cursor terminal_size key_chord palette navigation selection_anchor pid ref fun)
                  )

  @type t :: %{
          session_id: String.t(),
          sequence: non_neg_integer(),
          history: [map()],
          queues: %{steering: [map()], follow_up: [map()]},
          pending_interactions: %{String.t() => map()},
          permissions: %{String.t() => map()},
          control_state: %{String.t() => map()},
          active_run: map() | nil
        }

  @outcome_types ~w(run_completed run_failed)
  @control_types ~w(control_requested control_completed)
  @non_transcript_types @control_types ++ ~w(queue_changed)

  @doc "Returns the initial semantic state for one session."
  @spec new(String.t() | Identity.t()) :: t()
  def new(%{id: session_id}), do: new(session_id)

  def new(session_id) when is_binary(session_id) do
    %{
      session_id: session_id,
      sequence: 0,
      history: [],
      queues: %{steering: [], follow_up: []},
      pending_interactions: %{},
      permissions: %{},
      control_state: %{},
      active_run: nil
    }
  end

  @doc "Validates shared state recursively."
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(value), do: reject_forbidden(value, [])

  @doc "Returns a portable snapshot of semantic state."
  @spec to_protocol(t()) :: map()
  def to_protocol(state) do
    history = state.history

    %{
      "session_id" => state.session_id,
      "sequence" => state.sequence,
      "history" => history,
      "transcript" => Enum.reject(history, &(&1["type"] in @non_transcript_types)),
      "outcomes" => Enum.filter(history, &(&1["type"] in @outcome_types)),
      "controls" => Enum.filter(history, &(&1["type"] in @control_types)),
      "queues" => %{
        "steering" => state.queues.steering,
        "follow_up" => state.queues.follow_up
      },
      "pending_interactions" => state.pending_interactions,
      "permissions" => state.permissions,
      "control_state" => state.control_state,
      "active_run" => state.active_run
    }
  end

  @doc "Returns the canonical state stored in attach and recovery snapshots."
  @spec to_snapshot_protocol(t()) :: map()
  def to_snapshot_protocol(state) do
    %{
      "session_id" => state.session_id,
      "sequence" => state.sequence,
      "history" => state.history,
      "queues" => %{
        "steering" => state.queues.steering,
        "follow_up" => state.queues.follow_up
      },
      "active_run" => state.active_run
    }
  end

  defp reject_forbidden(value, _path)
       when is_pid(value) or is_reference(value) or is_function(value) or is_port(value) do
    {:error, :live_runtime_forbidden}
  end

  defp reject_forbidden(%Envelope{} = envelope, path) do
    envelope
    |> Envelope.to_map()
    |> reject_forbidden(path)
  end

  defp reject_forbidden(%module{} = _struct, _path) when module not in [Date, Time, DateTime, NaiveDateTime] do
    {:error, :raw_runtime_forbidden}
  end

  defp reject_forbidden(value, path) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      name = key_name(key)

      if MapSet.member?(@forbidden_keys, name) do
        {:halt, {:error, {:renderer_value_forbidden, Enum.reverse([name | path])}}}
      else
        case reject_forbidden(item, [name | path]) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    end)
  end

  defp reject_forbidden(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case reject_forbidden(item, [index | path]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reject_forbidden(_value, _path), do: :ok

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(key), do: inspect(key)
end
