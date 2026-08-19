defmodule Jido.Console.Session.Client.Driver do
  @moduledoc """
  Renderer-neutral behavior for semantic session clients.

  A driver owns no drawing, text formatting, JSON encoding, DOM, or transport
  callback. Live notifications are process-lifetime only.
  """

  alias Jido.Console.Session.Client.Handle

  @operations ~w(
    attach detach send steer queue remove invoke events status snapshot cancel
    approve reject receipt capabilities
  )

  @type result :: {:ok, term()} | {:error, term()} | :ok

  @callback attach(String.t(), keyword()) :: {:ok, Handle.t(), map()} | {:error, term()}
  @callback detach(Handle.t()) :: :ok | {:error, term()}
  @callback input(Handle.t(), :send | :steer | :queue | :remove, term()) :: result()
  @callback events(Handle.t()) :: result()
  @callback state(Handle.t(), :status | :snapshot) :: result()
  @callback control(Handle.t(), term()) :: result()
  @callback capabilities(Handle.t()) :: map()

  @doc "Returns the fixed renderer-neutral operation names."
  @spec operation_capabilities() :: [String.t()]
  def operation_capabilities, do: @operations
end
