defmodule Jido.Console.RuntimeStartup do
  @moduledoc false

  @spec invoke(keyword()) :: :ok | {:error, term()}
  def invoke(opts) do
    case Keyword.get(opts, :application_startup, fn -> :ok end) do
      startup when is_function(startup, 0) -> startup.()
      _startup -> {:error, :invalid_application_startup}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
