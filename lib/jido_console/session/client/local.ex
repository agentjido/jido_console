defmodule Jido.Console.Session.Client.Local do
  @moduledoc "Default in-process driver for the public session client contract."

  @behaviour Jido.Console.Session.Client.Driver

  alias Jido.Console.Session.{Catalog, Envelope, Identity, Registry, Server}
  alias Jido.Console.Session.Client.{Driver, Handle}

  @protocol "1"

  @impl true
  def attach(session_id, opts) do
    registry = Keyword.get(opts, :registry, Registry)

    with {:ok, descriptor} <- resolve_descriptor(opts),
         :ok <- require_protocol(descriptor),
         {:ok, capabilities} <- negotiate_capabilities(descriptor, opts),
         {:ok, server} <- Server.ensure_started(session_id, opts),
         {:ok, fence} <- Server.generation(server),
         {:ok, client} <- client_identity(session_id, fence, opts),
         {:ok, %{attachment: attachment, snapshot: snapshot}} <-
           Server.attach(server, client, attach_options(opts)),
         {:ok, snapshot} <- Envelope.validate(snapshot) do
      handle =
        Handle.new(
          session:
            Identity.new!(:session,
              id: session_id,
              session_id: session_id,
              generation: fence.generation,
              owner_instance_id: fence.owner_instance_id
            ),
          client: client,
          attachment: attachment,
          protocol: @protocol,
          capabilities: capabilities,
          descriptor: descriptor,
          private: %{
            registry: registry,
            catalog: Keyword.get(opts, :catalog, default_catalog()),
            driver: __MODULE__
          }
        )

      {:ok, handle, snapshot}
    end
  end

  @impl true
  def detach(handle), do: call(handle, :detach)

  @impl true
  def input(handle, operation, value), do: call(handle, {:input, operation, value})

  @impl true
  def output(handle) do
    case call(handle, :output) do
      {:ok, envelope} -> validate_delivery(envelope, "output_batch")
      {:gap, envelope} -> validate_gap(envelope)
      other -> other
    end
  end

  @impl true
  def state(handle, operation), do: call(handle, operation)

  @impl true
  def control(handle, operation), do: call(handle, operation)

  @impl true
  def delivery(handle, token), do: call(handle, {:delivery, token})

  @impl true
  def recovery(handle, :recover, gap_id) do
    handle
    |> call({:recovery, :recover, gap_id})
    |> validate_recovery("recovery_snapshot")
  end

  def recovery(handle, :replay, token) do
    handle
    |> call({:recovery, :replay, token})
    |> validate_recovery("recovery_suffix")
  end

  def recovery(handle, :resume, token) do
    handle
    |> call({:recovery, :resume, token})
    |> validate_recovery("recovery_receipt")
  end

  @impl true
  def capabilities(handle), do: Handle.capabilities(handle)

  @doc false
  @spec call(Handle.t(), term()) :: term()
  def call(handle, operation) do
    with {:ok, server} <- server(handle) do
      Server.client_operation(server, Handle.identity(handle), operation)
    end
  end

  @doc false
  @spec server(Handle.t()) :: {:ok, pid()} | {:error, term()}
  def server(handle) do
    identity = Handle.identity(handle)
    Registry.lookup(identity.session_id, Handle.registry(handle))
  end

  @doc false
  @spec default_catalog() :: Catalog.t()
  def default_catalog do
    descriptor = %{
      "id" => "jido.console.local",
      "version" => @protocol,
      "name" => "local",
      "capabilities" => Driver.operation_capabilities(),
      "provenance" => %{"owner" => "jido_console"}
    }

    {:ok, catalog} = Catalog.put_client(Catalog.new(), descriptor)
    catalog
  end

  defp resolve_descriptor(opts) do
    catalog = Keyword.get(opts, :catalog, default_catalog())
    descriptor = Keyword.get(opts, :descriptor, "local")

    case descriptor do
      value when is_map(value) ->
        with {:ok, catalog} <- Catalog.put_client(catalog, value),
             do: Catalog.fetch_client(catalog, value["id"] || value[:id])

      value when is_binary(value) ->
        Catalog.fetch_client(catalog, value)

      _other ->
        {:error, :invalid_client_descriptor}
    end
  end

  defp require_protocol(%{"version" => @protocol}), do: :ok
  defp require_protocol(_descriptor), do: {:error, :incompatible_client_protocol}

  defp negotiate_capabilities(descriptor, opts) do
    available = MapSet.new(descriptor["capabilities"])
    required = MapSet.new(Keyword.get(opts, :required_capabilities, []))
    optional = MapSet.new(Keyword.get(opts, :optional_capabilities, MapSet.to_list(available)))

    if MapSet.subset?(required, available) do
      negotiated = available |> MapSet.intersection(MapSet.union(required, optional)) |> MapSet.to_list() |> Enum.sort()

      {:ok,
       %{
         "version" => @protocol,
         "operations" => negotiated,
         "descriptive_only" => true,
         "grants_authority" => false,
         "delivery_limits" => Jido.Console.Session.Delivery.maximums()
       }}
    else
      {:error, {:required_capability_missing, MapSet.to_list(MapSet.difference(required, available))}}
    end
  end

  defp client_identity(session_id, fence, opts) do
    identity_opts =
      [
        session_id: session_id,
        generation: fence.generation,
        owner_instance_id: fence.owner_instance_id
      ]
      |> maybe_put(:id, Keyword.get(opts, :client_id))

    Identity.new(:client, identity_opts)
  end

  defp attach_options(opts) do
    [
      delivery_limits: Keyword.get(opts, :delivery_limits, %{})
    ]
    |> maybe_put(:token_secret, Keyword.get(opts, :token_secret))
  end

  defp validate_delivery(envelope, type) do
    with {:ok, envelope} <- Envelope.validate(envelope),
         true <- envelope["family"] == "delivery" and envelope["type"] == type,
         false <- Enum.any?(envelope["payload"]["events"], &(&1["type"] == "delivery_gap")) do
      {:ok, envelope}
    else
      false -> {:error, :invalid_client_output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_gap(envelope) do
    with {:ok, envelope} <- Envelope.validate(envelope),
         true <- envelope["family"] == "delivery" and envelope["type"] == "gap" do
      {:gap, envelope}
    else
      false -> {:error, :invalid_client_output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_recovery({:ok, envelope}, type) do
    with {:ok, envelope} <- Envelope.validate(envelope),
         true <- envelope["family"] == "delivery" and envelope["type"] == type do
      {:ok, envelope}
    else
      false -> {:error, :invalid_client_recovery}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_recovery(other, _type), do: other

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
