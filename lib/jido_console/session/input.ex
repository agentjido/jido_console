defmodule Jido.Console.Session.Input do
  @moduledoc "Durable input identity and its restart-safe admission receipt."

  alias Jido.Console.Session.{Admission, Identity}

  @states [:accepted, :started, :completed, :rejected, :cancelled]

  @type t :: %{
          identity: Identity.t(),
          text: String.t(),
          idempotency_key: String.t(),
          receipt: map() | nil,
          status: atom(),
          wakeups: non_neg_integer()
        }

  @doc "Accepts input and assigns an identity before any wake-up is sent."
  @spec admit(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def admit(text, opts) when is_binary(text) do
    idempotency_key = Keyword.get(opts, :idempotency_key)

    with :ok <- Admission.validate_idempotency_key(idempotency_key),
         {:ok, identity} <-
           Identity.new(
             :input,
             Keyword.take(opts, [:session_id, :id, :generation, :owner_instance_id])
           ) do
      {:ok,
       %{
         identity: identity,
         text: text,
         idempotency_key: idempotency_key,
         receipt: Keyword.get(opts, :receipt),
         status: :accepted,
         wakeups: 0
       }}
    end
  end

  @doc "Records a coalesced wake-up without changing admitted input."
  @spec wakeup(t()) :: t()
  def wakeup(input), do: %{input | wakeups: input.wakeups + 1}

  @doc "Transitions an admitted input."
  @spec transition(t(), atom()) :: {:ok, t()} | {:error, term()}
  def transition(input, status) when status in @states, do: {:ok, %{input | status: status}}
  def transition(_input, status), do: {:error, {:invalid_input_status, status}}

  @doc "Returns the durable input and advisory wake-up boundary."
  @spec crash_limitation() :: String.t()
  def crash_limitation do
    "Accepted durable input survives an application restart. Advisory wake-up remains recoverable work."
  end
end
