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
         :ok <- reject_invalid_order(projected, Keyword.get(opts, :last_jidoka_seq)) do
      Event.classify(%{
        type: console_type(projected),
        sequence: Keyword.fetch!(opts, :sequence),
        durability: "process",
        sensitivity: sensitivity(projected),
        origin: %{kind: "jidoka", actor_id: projected[:request_id] || "jidoka"},
        trust: %{evidence: "jidoka-projection", policy: "session-owner"},
        identities: identities(projected, opts),
        request_id: projected[:request_id],
        run_id: projected[:turn_id]
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

  defp console_type(%{terminal?: true, event: "turn_failed"}), do: "run_failed"
  defp console_type(%{terminal?: true}), do: "run_completed"
  defp console_type(%{event: "llm_delta"}), do: "model_delta"
  defp console_type(_projected), do: "run_progress"

  defp sensitivity(%{data: %{"token" => _}}), do: "redacted"
  defp sensitivity(_projected), do: "public"

  defp identities(projected, opts) do
    session = Keyword.get_lazy(opts, :session, fn -> Identity.new!(:session) end)

    [
      Identity.to_protocol(session),
      %{
        "kind" => "request",
        "id" => projected[:request_id] || "req_unknown",
        "session_id" => session.id
      }
    ]
  end
end
