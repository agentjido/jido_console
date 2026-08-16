defmodule Jido.Console.Session.Request do
  @moduledoc """
  Portable handle for work that is owned by one supervised Console session.

  The raw Jidoka request stays inside `Jido.Console.Session.Server`. Clients
  receive only process-lifetime identities that they can use for await,
  cancellation, and result correlation.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              request_id: Zoi.string(),
              run_id: Zoi.string(),
              session_id: Zoi.string()
            },
            unrecognized_keys: :error
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @type t :: %__MODULE__{
          id: String.t(),
          request_id: String.t(),
          run_id: String.t(),
          session_id: String.t()
        }
end
