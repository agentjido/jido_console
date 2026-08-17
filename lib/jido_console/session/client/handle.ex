defmodule Jido.Console.Session.Client.Handle do
  @moduledoc """
  Opaque process-lifetime handle for one exact session attachment.

  The value contains public identities and bounded capability data. It does
  not contain a server PID, runtime handle, delivery state, or snapshot cache.
  """

  alias Jido.Console.Session.Identity

  @schema Zoi.struct(
            __MODULE__,
            %{
              session: Zoi.struct(Identity),
              client: Zoi.struct(Identity),
              attachment: Zoi.struct(Identity),
              protocol: Zoi.string(),
              capabilities: Zoi.map(),
              descriptor: Zoi.map(),
              private: Zoi.map()
            },
            unrecognized_keys: :error
          )

  @opaque t :: %__MODULE__{
            session: Identity.t(),
            client: Identity.t(),
            attachment: Identity.t(),
            protocol: String.t(),
            capabilities: map(),
            descriptor: map(),
            private: map()
          }

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc "Returns the exact public attachment identity tuple."
  @spec identity(t()) :: map()
  def identity(handle) do
    %{
      session_id: handle.session.id,
      client_id: handle.client.id,
      attachment_id: handle.attachment.id
    }
  end

  @doc false
  @spec private(t()) :: map()
  def private(handle), do: handle.private

  @doc false
  @spec session(t()) :: Identity.t()
  def session(handle), do: handle.session

  @doc false
  @spec client(t()) :: Identity.t()
  def client(handle), do: handle.client

  @doc false
  @spec attachment(t()) :: Identity.t()
  def attachment(handle), do: handle.attachment

  @doc false
  @spec protocol(t()) :: String.t()
  def protocol(handle), do: handle.protocol

  @doc false
  @spec capabilities(t()) :: map()
  def capabilities(handle), do: handle.capabilities

  @doc false
  @spec descriptor(t()) :: map()
  def descriptor(handle), do: handle.descriptor

  @doc false
  @spec registry(t()) :: atom()
  def registry(handle), do: handle.private.registry

  @doc false
  @spec catalog(t()) :: map()
  def catalog(handle), do: handle.private.catalog

  @doc false
  @spec driver(t()) :: module()
  def driver(handle), do: handle.private.driver
end

defimpl Inspect, for: Jido.Console.Session.Client.Handle do
  import Inspect.Algebra

  def inspect(handle, opts) do
    public =
      Map.take(handle, [:session, :client, :attachment, :protocol, :capabilities, :descriptor])

    concat(["#Jido.Console.Session.Client<", to_doc(public, opts), ">"])
  end
end
