defmodule Jido.Console.Session.JidokaBridge do
  @moduledoc "Stateless linked bridge from one thread owner to the public Jidoka API."

  @doc "Links to the owner, waits for begin, and runs one public Jidoka action."
  @spec run(pid(), reference(), map()) :: :ok
  def run(owner, run_ref, action) when is_pid(owner) and is_reference(run_ref) and is_map(action) do
    Process.link(owner)
    send(owner, {:bridge_linked, self(), run_ref})

    receive do
      {:begin, ^run_ref} -> execute(owner, run_ref, action)
    end
  end

  defp execute(owner, run_ref, %{kind: :prompt} = action) do
    request_id = action.request_id
    opts = runtime_opts(owner, run_ref, action)

    case Jidoka.Session.chat_async(action.thread_id, action.prompt, opts) do
      {:ok, request} ->
        send(owner, {:bridge_handle, self(), run_ref, request_id, request})
        result = Jidoka.await(request, timeout: :infinity, cancel_on_timeout: false)
        send(owner, {:bridge_result, self(), run_ref, request_id, result})

      {:error, reason} ->
        send(owner, {:bridge_result, self(), run_ref, request_id, {:error, reason}})
    end

    :ok
  end

  defp execute(owner, run_ref, %{kind: decision} = action) when decision in [:approve, :deny] do
    result =
      case decision do
        :approve -> Jidoka.approve(action.session, action.review_id, runtime_opts(owner, run_ref, action))
        :deny -> Jidoka.deny(action.session, action.review_id, runtime_opts(owner, run_ref, action))
      end

    send(owner, {:bridge_result, self(), run_ref, action.request_id, result})
    :ok
  end

  defp runtime_opts(owner, run_ref, action) do
    action.runtime_opts
    |> Keyword.put(:store, action.store)
    |> Keyword.put(:request_id, action.request_id)
    |> Keyword.put(:context, Map.get(action, :context, %{}))
    |> Keyword.put(:on_event, fn event ->
      send(owner, {:bridge_event, run_ref, action.request_id, event})
    end)
  end
end
