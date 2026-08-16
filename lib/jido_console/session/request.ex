defmodule Jido.Console.Session.Request do
  @moduledoc """
  Portable handle for work that is owned by one supervised Console session.

  The raw Jidoka request stays inside `Jido.Console.Session.Server`. Clients
  receive only process-lifetime identities that they can use for await,
  cancellation, and result correlation.
  """

  @enforce_keys [:id, :request_id, :run_id, :session_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          request_id: String.t(),
          run_id: String.t(),
          session_id: String.t()
        }
end
