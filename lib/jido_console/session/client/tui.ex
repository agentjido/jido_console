defmodule Jido.Console.Session.Client.TUI do
  @moduledoc """
  Canonical bounded Session.Client projection for the production TUI.

  Renderer-only state stays in the TUI process. This module applies complete
  batches before acknowledgement and uses snapshots only for attach or gap
  recovery.
  """

  alias Jido.Console.Session.Client
  alias Jido.Console.Session.Client.Handle
  alias Jido.Console.Tui.State

  @doc "Attaches the TUI and returns the exact handle and attach snapshot."
  @spec attach(String.t(), keyword()) :: {:ok, Client.attach_result()} | {:error, term()}
  def attach(session_id, opts \\ []), do: Client.attach(session_id, opts)

  @doc "Detaches the exact TUI attachment while session work continues."
  @spec detach(Client.t()) :: :ok | {:error, term()}
  def detach(handle), do: Client.detach(handle)

  @doc "Creates a new attachment for the same logical client and session."
  @spec reattach(Client.t(), keyword()) :: {:ok, Client.attach_result()} | {:error, term()}
  def reattach(handle, opts \\ []) do
    identity = Handle.identity(handle)
    _result = Client.detach(handle)
    Client.attach(identity.session_id, Keyword.put(opts, :client_id, identity.client_id))
  end

  @doc "Applies one bounded batch and acknowledges only the complete result."
  @spec apply_batch(Client.t(), State.t(), map()) ::
          {:ok, State.t()} | {:error, term(), State.t()}
  def apply_batch(handle, state, batch) do
    events = get_in(batch, ["payload", "events"])
    token = get_in(batch, ["payload", "acknowledgement_token"])

    with true <- batch["family"] == "delivery" and batch["type"] == "output_batch",
         true <- is_list(events) and is_binary(token),
         {:ok, projected} <- State.apply_session_events(state, events),
         {:ok, _receipt} <- Client.ack(handle, token) do
      {:ok, projected}
    else
      false -> {:error, :invalid_tui_output_batch, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc "Pulls and applies one normal batch or performs exact gap recovery."
  @spec consume(Client.t(), State.t()) ::
          {:ok, State.t()} | {:empty, State.t()} | {:error, term(), State.t()}
  def consume(handle, state) do
    case Client.output(handle) do
      {:ok, batch} -> apply_batch(handle, state, batch)
      {:gap, gap} -> recover(handle, state, gap)
      :empty -> {:empty, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc "Applies snapshot and suffix before exact recovery completion."
  @spec recover(Client.t(), State.t(), map()) :: {:ok, State.t()} | {:error, term(), State.t()}
  def recover(handle, state, gap) do
    with {:ok, snapshot} <- Client.recover(handle, gap),
         {:ok, info} <- Client.runtime_info(handle),
         restored = State.restore_snapshot(state, snapshot, info.active_request),
         {:ok, suffix} <- Client.replay(handle, snapshot["payload"]["recovery_token"]),
         events when is_list(events) <- suffix["payload"]["events"],
         {:ok, projected} <- State.apply_session_events(restored, events),
         true <- projected.semantic_sequence == suffix["payload"]["through_sequence"],
         {:ok, _receipt} <- Client.resume(handle, suffix["payload"]["completion_token"]) do
      {:ok, projected}
    else
      false -> {:error, :invalid_tui_recovery_sequence, state}
      nil -> {:error, :invalid_tui_recovery_suffix, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc "Returns ordered canonical event types visible to the TUI."
  @spec observe(Client.t()) :: [String.t()]
  def observe(handle) do
    case Client.snapshot(handle) do
      {:ok, snapshot} ->
        snapshot
        |> get_in(["payload", "state", "transcript"])
        |> List.wrap()
        |> Enum.map(& &1["type"])

      {:error, _reason} ->
        []
    end
  end
end
