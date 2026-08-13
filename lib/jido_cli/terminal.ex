defmodule Jido.Cli.Terminal do
  @moduledoc """
  Small, injectable terminal boundary for Jido applications.

  The adapter owns all terminal effects. `Jido.Cli.Terminal.Input` and
  `Jido.Cli.Terminal.Frame` are pure and can be tested without a TTY.
  """

  alias Jido.Cli.Terminal.Frame

  @enforce_keys [:adapter, :handle, :ref, :size]
  defstruct [:adapter, :handle, :ref, :size]

  @type t :: %__MODULE__{
          adapter: module(),
          handle: term(),
          ref: reference(),
          size: {pos_integer(), pos_integer()}
        }

  @doc "Opens a terminal with an injectable adapter."
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts \\ []) do
    adapter = Keyword.get(opts, :adapter, Jido.Cli.Terminal.OTP)
    owner = Keyword.get(opts, :owner, self())
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    with {:ok, handle, ref, size} <- adapter.open(owner, adapter_opts) do
      {:ok, %__MODULE__{adapter: adapter, handle: handle, ref: ref, size: size}}
    end
  end

  @doc "Draws one complete frame."
  @spec draw(t(), Frame.t()) :: :ok | {:error, term()}
  def draw(%__MODULE__{} = terminal, %Frame{} = frame) do
    terminal.adapter.write(terminal.handle, Frame.to_iodata(frame))
  end

  @doc "Reads the current terminal size and returns an updated terminal."
  @spec resize(t()) :: {:ok, t()} | {:error, term()}
  def resize(%__MODULE__{} = terminal) do
    with {:ok, size} <- terminal.adapter.size(terminal.handle) do
      {:ok, %{terminal | size: size}}
    end
  end

  @doc "Closes the terminal. This function can be called more than once."
  @spec close(t()) :: :ok
  def close(%__MODULE__{} = terminal), do: terminal.adapter.close(terminal.handle)
end
