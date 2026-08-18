defmodule Jido.Console.Credential.Keychain do
  @moduledoc "Read-only operating-system keychain adapter contract."

  @callback read(map(), keyword()) :: {:ok, binary()} | :missing | {:error, term()}
end
