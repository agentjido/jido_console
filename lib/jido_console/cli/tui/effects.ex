defmodule Jido.Console.Tui.Effects do
  @moduledoc false

  alias Jido.Console.Session.Client
  alias Jido.Console.Tui.{State, Workers}
  alias Jido.Console.Tui.Workers.Worker

  @type completion :: {:event, term()} | :ignore

  @spec dispatch(State.t(), [State.effect()], module(), keyword(), Workers.t()) ::
          {:continue | :exit, Workers.t()}
  def dispatch(state, effects, _runtime, opts, workers) do
    client = Keyword.get(opts, :session_client_module, Client)

    Enum.reduce_while(effects, {:continue, workers}, fn
      :exit, {:continue, workers} ->
        {:halt, {:exit, workers}}

      {:start_turn, prompt}, {:continue, workers} ->
        {:cont, {:continue, start_turn(workers, state.session_client, client, opts, prompt, %{})}}

      {:cancel_turn, request}, {:continue, workers} ->
        workers =
          Workers.start(workers, :session_cancel, fn -> client.cancel(state.session_client, request_id(request)) end)

        {:cont, {:continue, workers}}

      {:respond_review, decision, request, _result, review}, {:continue, workers}
      when decision in [:approve, :deny] ->
        workers =
          Workers.start(workers, {:session_review, decision}, fn ->
            case decision do
              :approve -> client.approve(state.session_client, request_id(request), review_id(review))
              :deny -> client.deny(state.session_client, request_id(request), review_id(review))
            end
          end)

        {:cont, {:continue, workers}}
    end)
  end

  @spec complete(Worker.t(), {:ok, term()} | {:crash, term()}) :: completion()
  def complete(%Worker{kind: :session_start_turn}, outcome) do
    case outcome do
      {:ok, {:ok, accepted}} when is_map(accepted) -> {:event, {:turn_started, accepted}}
      {:ok, {:error, reason}} -> {:event, {:turn_result, {:error, reason}}}
      {:crash, reason} -> {:event, {:turn_result, {:error, reason}}}
      {:ok, other} -> {:event, {:turn_result, {:error, {:invalid_submit_result, other}}}}
    end
  end

  def complete(%Worker{kind: kind}, outcome) when kind == :session_cancel or elem(kind, 0) == :session_review do
    case outcome do
      {:ok, {:ok, :requested}} -> :ignore
      {:ok, {:error, :request_already_finished}} -> :ignore
      {:ok, {:error, :review_pending}} -> :ignore
      {:ok, {:error, reason}} -> {:event, {:turn_result, {:error, reason}}}
      {:crash, reason} -> {:event, {:turn_result, {:error, reason}}}
      {:ok, other} -> {:event, {:turn_result, {:error, {:invalid_control_result, other}}}}
    end
  end

  defp start_turn(workers, session_client, client, opts, prompt, context) do
    command_id = stable_id(opts, "tui-command")
    request_id = stable_id(opts, "tui-request")

    Workers.start(workers, :session_start_turn, fn ->
      client.submit(session_client, prompt,
        command_id: command_id,
        request_id: request_id,
        context: context
      )
    end)
  end

  defp stable_id(opts, prefix) do
    case Keyword.get(opts, :id_generator) do
      fun when is_function(fun, 1) -> fun.(prefix)
      _other -> Jidoka.Id.generate!(prefix)
    end
  end

  defp request_id(request), do: Map.get(request, :request_id, Map.get(request, "request_id"))
  defp review_id(review), do: Map.get(review, :id, Map.get(review, "id"))
end
