defmodule Jido.Console.Session.Projection do
  @moduledoc """
  Projects Jidoka events into classified Console events at one boundary.

  The caller supplies the next Console sequence. This module does not allocate
  or store live sequence state. Duplicate Jidoka identities are ignored.
  Invalid Jidoka order fails without producing a Console event.
  """

  alias Jido.Console.Session.{Event, Identity, Jidoka}

  @doc "Projects one Jidoka event or portable projection into a Console event."
  @spec project(term(), keyword()) :: {:ok, map()} | {:ignore, :duplicate} | {:error, term()}
  def project(source, opts) when is_list(opts) do
    with {:ok, projected} <- portable(source),
         :ok <- reject_duplicate(projected, Keyword.get(opts, :seen, MapSet.new())),
         :ok <- reject_invalid_order(projected, Keyword.get(opts, :last_jidoka_seq)),
         {:ok, session} <- session_identity(opts) do
      Event.classify(%{
        type: console_type(projected),
        id: event_id(projected, opts),
        session_id: session.id,
        sequence: Keyword.fetch!(opts, :sequence),
        durability: "process",
        sensitivity: sensitivity(projected),
        origin: %{kind: "jidoka", actor_id: projected[:request_id] || "jidoka"},
        trust: %{evidence: "jidoka-projection", policy: "session-owner"},
        identities: identities(projected, session),
        request_id: projected[:request_id],
        run_id: projected[:turn_id],
        jidoka_sequence: projected[:seq],
        jidoka_event: projected[:event],
        terminal: projected[:terminal?],
        effect_id: projected[:effect_id],
        effect_kind: projected[:effect_kind],
        operation: projected[:operation],
        status: projected[:status],
        data: projected[:data],
        error: projected[:error]
      })
    end
  end

  defp portable(%{__struct__: _module} = source), do: Jidoka.project_events(source)
  defp portable(%{request_id: _request_id} = projected), do: {:ok, projected}
  defp portable(source), do: Jidoka.project_events(source)

  defp reject_duplicate(projected, seen) do
    key = {projected[:request_id], projected[:seq]}

    if MapSet.member?(seen, key) do
      {:ignore, :duplicate}
    else
      :ok
    end
  end

  defp reject_invalid_order(%{seq: seq}, last) when is_integer(last) and seq != last + 1 do
    {:error, {:invalid_jidoka_order, last, seq}}
  end

  defp reject_invalid_order(_projected, _last), do: :ok

  defp console_type(%{event: event}) when event in ["turn_failed", :turn_failed], do: "run_failed"

  defp console_type(%{event: event}) when event in ["turn_hibernated", :turn_hibernated],
    do: "run_progress"

  defp console_type(%{event: event}) when event in ["llm_delta", :llm_delta], do: "model_delta"
  defp console_type(%{terminal?: true}), do: "run_completed"
  defp console_type(_projected), do: "run_progress"

  defp event_id(projected, opts) do
    request_id = projected[:request_id] || "jidoka"
    seq = projected[:seq] || Keyword.fetch!(opts, :sequence)
    "plt_#{request_id}_#{seq}"
  end

  defp sensitivity(%{data: %{"token" => _}}), do: "redacted"
  defp sensitivity(_projected), do: "public"

  defp identities(projected, session) do
    [
      Identity.to_protocol(session),
      %{
        "kind" => "request",
        "id" => projected[:request_id] || "req_unknown",
        "session_id" => session.id
      }
    ]
  end

  defp session_identity(opts) do
    case Keyword.fetch(opts, :session) do
      {:ok, %{kind: :session, id: id, session_id: id} = session} when is_binary(id) and id != "" ->
        {:ok, session}

      {:ok, _invalid} ->
        {:error, :invalid_session_identity}

      :error ->
        case Keyword.fetch(opts, :session_id) do
          {:ok, session_id} -> Identity.new(:session, id: session_id)
          :error -> {:error, :session_identity_missing}
        end
    end
  end
end
