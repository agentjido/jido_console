defmodule Jido.Console.Tui.Activity do
  @moduledoc "Tagged semantic activity for the interactive TUI."

  alias Jido.Console.Session.Request
  alias Jido.Console.Tui.Turn

  @type decision :: :approve | :deny
  @type failure_kind :: :startup | :preparation | :selection | :turn | :hibernated
  @type t ::
          :idle
          | {:preparing, {:prompt, String.t()}}
          | {:preparing, {:selection, term()}}
          | {:starting, {:runtime, :empty | :submit_when_ready}}
          | {:starting, {:turn, Turn.t()}}
          | {:active, Request.t(), Turn.t(), :streaming | :finishing}
          | {:review, Request.t(), Turn.t(), map(), :awaiting | {:responding, decision()}}
          | {:cancelling, Turn.t(), :before_start | {:request, Request.t()}}
          | {:failed, failure_kind(), term(), String.t()}

  @spec tag(t()) :: :idle | :preparing | :starting | :active | :review | :cancelling | :failed
  def tag(:idle), do: :idle
  def tag({tag, _data}) when tag in [:preparing, :starting], do: tag
  def tag({tag, _first, _second, _third}) when tag in [:active, :failed], do: tag
  def tag({:review, _request, _turn, _result, _response}), do: :review
  def tag({:cancelling, _turn, _target}), do: :cancelling

  @spec turn(t()) :: Turn.t() | nil
  def turn({:starting, {:turn, turn}}), do: turn
  def turn({:active, _request, turn, _phase}), do: turn
  def turn({:review, _request, turn, _result, _response}), do: turn
  def turn({:cancelling, turn, _target}), do: turn
  def turn(_activity), do: nil

  @spec request(t()) :: Request.t() | nil
  def request({:active, request, _turn, _phase}), do: request
  def request({:review, request, _turn, _result, _response}), do: request
  def request({:cancelling, _turn, {:request, request}}), do: request
  def request(_activity), do: nil

  @spec streaming(t()) :: String.t()
  def streaming(activity) do
    case turn(activity) do
      %Turn{assistant: assistant} -> assistant
      nil -> ""
    end
  end

  @spec error(t()) :: String.t() | nil
  def error({:failed, _kind, _reason, message}), do: message
  def error(_activity), do: nil

  @spec replace_turn(t(), Turn.t()) :: t()
  def replace_turn({:starting, {:turn, _turn}}, turn), do: {:starting, {:turn, turn}}
  def replace_turn({:active, request, _turn, phase}, turn), do: {:active, request, turn, phase}

  def replace_turn({:review, request, _turn, result, response}, turn),
    do: {:review, request, turn, result, response}

  def replace_turn({:cancelling, _turn, target}, turn), do: {:cancelling, turn, target}
  def replace_turn(activity, _turn), do: activity
end
