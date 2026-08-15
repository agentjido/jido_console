defmodule Jido.Console.Terminal.Adapter do
  @moduledoc "Adapter contract for terminal effects."

  @type handle :: term()
  @type size :: {pos_integer(), pos_integer()}
  @type event ::
          {:text, String.t()}
          | {:paste, String.t()}
          | {:key,
             :enter
             | :newline
             | :backspace
             | :left
             | :right
             | :up
             | :down
             | :page_up
             | :page_down
             | :escape
             | :ctrl_c}
          | {:resize, pos_integer(), pos_integer()}
          | :eof

  @callback open(owner :: pid(), keyword()) ::
              {:ok, handle(), reference(), size()} | {:error, term()}
  @callback write(handle(), iodata()) :: :ok | {:error, term()}
  @callback size(handle()) :: {:ok, size()} | {:error, term()}
  @callback close(handle()) :: :ok
end
