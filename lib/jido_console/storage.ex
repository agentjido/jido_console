defmodule Jido.Console.Storage do
  @moduledoc "Public access to the single SQLite writer."

  alias Jido.Console.Session.{Event, State}

  @deadline 1_000
  @states ~w(accepted started terminal)

  @doc "Appends one canonical event."
  @spec append_event(map(), State.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def append_event(event, semantic, opts \\ []) when is_map(event) and is_map(semantic) do
    with {:ok, event} <- Event.validate(event),
         true <- event.session_id == semantic.session_id,
         true <- event.payload["sequence"] == semantic.sequence do
      write_call({:append_event, event}, opts, event.id)
    else
      false -> {:error, :invalid_semantic_history_position}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Commits one operation and event atomically."
  @spec admit_operation(map(), map(), State.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def admit_operation(prepared, event, semantic, opts \\ [])
      when is_map(prepared) and is_map(event) and is_map(semantic) do
    with {:ok, event} <- Event.validate(event),
         true <- event.session_id == semantic.session_id,
         true <- event.payload["sequence"] == semantic.sequence do
      write_call({:admit_operation, prepared, event}, opts, prepared.operation_id)
    else
      false -> {:error, :invalid_semantic_history_position}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns one admission receipt."
  @spec admission_receipt(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def admission_receipt(operation_id, opts \\ []) when is_binary(operation_id) do
    read_call({:operation, operation_id}, opts)
  end

  @doc "Changes one admission state."
  @spec transition_admission(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def transition_admission(operation_id, state, opts \\ [])
      when is_binary(operation_id) and state in @states do
    write_call({:transition_operation, operation_id, state}, opts, operation_id)
  end

  @doc "Returns bounded admissions for one session."
  @spec recover_admissions(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def recover_admissions(session_id, opts \\ []) when is_binary(session_id) do
    states = Keyword.get(opts, :states, @states)
    limit = Keyword.get(opts, :limit, 100)

    if is_list(states) and states != [] and Enum.all?(states, &(&1 in @states)) and is_integer(limit) and
         limit > 0 and limit <= 1_000 do
      read_call({:operations, session_id, states, limit}, opts)
    else
      {:error, :invalid_admission_recovery_bounds}
    end
  end

  @doc "Returns all canonical events for one session."
  @spec events(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def events(session_id, opts \\ []) when is_binary(session_id) do
    read_call({:events, session_id}, opts)
  end

  @doc "Returns the last canonical event identity for one session."
  @spec history_head(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def history_head(session_id, opts \\ []) when is_binary(session_id) do
    read_call({:history_head, session_id}, opts)
  end

  @doc "Stores one credential profile version."
  @spec put_credential_profile(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def put_credential_profile(profile, operation_id, opts \\ [])
      when is_map(profile) and is_binary(operation_id) and operation_id != "" do
    write_call({:put_profile, profile, operation_id}, opts, operation_id)
  end

  @doc "Returns all versions of one credential profile."
  @spec credential_profile_history(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def credential_profile_history(profile_id, opts \\ []) when is_binary(profile_id) do
    read_call({:profile_history, profile_id}, opts)
  end

  @doc "Returns the latest credential profiles."
  @spec credential_profiles(keyword()) :: {:ok, [map()]} | {:error, term()}
  def credential_profiles(opts \\ []), do: read_call(:profiles, opts)

  @doc "Checks SQLite and stored payload integrity."
  @spec inspect_store(keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_store(opts \\ []), do: read_call(:inspect_store, opts)

  @doc "Returns small store counts."
  @spec status(keyword()) :: {:ok, map()} | {:error, term()}
  def status(opts \\ []), do: read_call(:status, opts)

  defp write_call(message, opts, operation_id) do
    GenServer.call(writer(opts), message, deadline(opts))
  catch
    :exit, {:timeout, _call} -> {:error, {:timeout_unknown, operation_id}}
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp read_call(message, opts) do
    GenServer.call(writer(opts), message, deadline(opts))
  catch
    :exit, {:timeout, _call} -> {:error, :storage_reader_timeout}
    :exit, _reason -> {:error, :storage_unavailable}
  end

  defp writer(opts), do: Keyword.get(opts, :writer, Jido.Console.Storage.Writer)
  defp deadline(opts), do: Keyword.get(opts, :deadline, @deadline)
end
