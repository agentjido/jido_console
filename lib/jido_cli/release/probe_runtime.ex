defmodule Jido.Cli.Release.ProbeRuntime do
  @moduledoc false
  @behaviour Jido.Cli.Runtime

  alias Jidoka.Cancellation
  alias Jidoka.Event

  @impl true
  def start_session(_agent, _opts), do: {:ok, :release_probe_session}

  @impl true
  def start_turn(:release_probe_session, prompt, owner, _opts) do
    request = %{request_id: "release-probe", prompt: prompt}
    record_turn(prompt)

    delta =
      Event.build(:llm_delta, [],
        request_id: request.request_id,
        data: %{chunk_type: :content, delta: "Release probe completed."}
      )

    send(owner, {:jidoka_turn_event, delta})
    send(owner, {:jidoka_turn_event, Event.build(:turn_finished, [delta], request_id: request.request_id)})
    {:ok, request}
  end

  @impl true
  def await(_request, _opts), do: {:ok, :release_probe_session, "Release probe completed."}

  @impl true
  def cancel(request, _opts) do
    {:ok, Cancellation.new!(request_id: request.request_id, cancelled_at_ms: 0)}
  end

  @impl true
  def close_session(:release_probe_session), do: :ok

  defp record_turn(prompt) do
    case System.get_env("JIDO_RELEASE_TUI_PROBE_LOG") do
      nil -> :ok
      path -> File.write(path, "turn #{sha256(prompt)}\n", [:append])
    end
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
