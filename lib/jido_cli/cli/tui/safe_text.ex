defmodule Jido.Cli.Tui.SafeText do
  @moduledoc false

  alias Jido.Cli.Terminal.PlainText

  @summary_limit 240

  @spec clean(term()) :: String.t()
  def clean(value), do: PlainText.clean(value)

  @spec summary(term(), keyword()) :: String.t()
  def summary(value, opts \\ []) do
    limit = Keyword.get(opts, :limit, @summary_limit)

    PlainText.summary(value, limit)
  end
end
