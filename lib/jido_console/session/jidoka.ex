defmodule Jido.Console.Session.Jidoka do
  @moduledoc """
  Console facade over the approved immutable Jidoka contracts.

  This module is the only Console durability boundary for Jidoka session data.
  It validates the durable Console-to-Jidoka session mapping before each state
  transition. It also limits Console receipt metadata before that metadata is
  added to a Jidoka request.

  Console generation values and Jidoka lease values are separate fences. This
  facade does not convert one value into the other.
  """

  alias Jido.Console.Session.Durable.CanonicalJSON
  alias Jido.Console.Session.Generation
  alias Jido.Console.Session.Protocol
  alias Jido.Console.Session.Protocol.Validator
  alias Jido.Console.Release.Identity
  alias Jidoka.Event
  alias Jidoka.Event.Order
  alias Jidoka.Session.Data
  alias Jidoka.Session.Lease
  alias Jidoka.Session.Lineage
  alias Jidoka.Session.Store
  alias Jidoka.Session.Transitions
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  @namespace "jido_console"
  @mapping_kinds ~w(normal imported forked)

  @type session_mapping :: %{String.t() => String.t()}

  @doc "Returns the approved durable Jidoka schema and codec contract."
  @spec durable_contract() :: map()
  def durable_contract do
    release = Identity.current()

    %{
      jidoka_ref: release.jidoka_ref,
      jidoka_version: release.jidoka,
      session_schema_version: Data.schema_version(),
      supported_session_schema_versions: Data.supported_schema_versions(),
      snapshot_schema_version: Snapshot.schema_version(),
      supported_snapshot_schema_versions: Snapshot.supported_schema_versions(),
      snapshot_serialization_prefix: Snapshot.serialization_prefix()
    }
  end

  @doc "Builds an explicit durable Console-to-Jidoka session mapping."
  @spec session_mapping(String.t(), keyword()) :: {:ok, session_mapping()} | {:error, term()}
  def session_mapping(console_session_id, opts \\ []) when is_list(opts) do
    jidoka_session_id = Keyword.get(opts, :jidoka_session_id, console_session_id)

    with {:ok, kind} <- mapping_kind(Keyword.get(opts, :kind, :normal)),
         mapping = %{
           "console_session_id" => console_session_id,
           "jidoka_session_id" => jidoka_session_id,
           "kind" => kind
         },
         :ok <- validate_mapping_shape(mapping),
         :ok <- validate_mapping_rule(mapping) do
      {:ok, mapping}
    end
  end

  @doc "Validates one mapping against durable Jidoka session data."
  @spec validate_session(session_mapping(), Data.t()) :: :ok | {:error, term()}
  def validate_session(mapping, %Data{} = session) do
    with :ok <- validate_mapping_shape(mapping),
         :ok <- validate_mapping_rule(mapping) do
      equal_jidoka_session(mapping, session.session_id)
    end
  end

  def validate_session(_mapping, _session), do: {:error, :invalid_jidoka_session_mapping}

  @doc "Builds the one bounded Console namespace for Jidoka request metadata."
  @spec request_metadata(map()) :: {:ok, map()} | {:error, term()}
  def request_metadata(receipt) when is_map(receipt) do
    with {:ok, receipt} <- Validator.validate(receipt),
         :ok <- validate_receipt(receipt),
         {:ok, bounds} <- protocol_bounds(),
         :ok <- validate_receipt_count(receipt, bounds),
         metadata = %{@namespace => %{"receipt" => receipt}},
         {:ok, encoded} <- CanonicalJSON.encode(metadata),
         :ok <- validate_metadata_bytes(encoded, bounds) do
      {:ok, metadata}
    end
  end

  def request_metadata(_receipt), do: {:error, :invalid_console_receipt_metadata}

  @doc "Returns the exact count and byte limits for Console request metadata."
  @spec request_metadata_limits() :: %{max_keys: pos_integer(), max_bytes: pos_integer()}
  def request_metadata_limits do
    {:ok, bounds} = protocol_bounds()
    %{max_keys: bounds["max_unknown_keys"], max_bytes: bounds["max_unknown_bytes"]}
  end

  @doc "Applies the public direct-write transition after mapping validation."
  @spec put_transition(session_mapping(), Data.t() | nil, Data.t()) ::
          {:ok, Data.t()} | {:error, term()}
  def put_transition(mapping, current, %Data{} = incoming) do
    with :ok <- validate_optional_session(mapping, current),
         :ok <- validate_session(mapping, incoming) do
      Transitions.put(current, incoming)
    end
  end

  @doc "Applies the public claim transition after mapping validation."
  @spec claim_transition(session_mapping(), Data.t(), Turn.Request.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def claim_transition(mapping, %Data{} = session, %Turn.Request{} = request, opts \\ []) do
    with :ok <- validate_session(mapping, session) do
      Transitions.claim(session, request, opts)
    end
  end

  @doc "Applies the public resume transition after mapping validation."
  @spec resume_transition(session_mapping(), Data.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def resume_transition(mapping, %Data{} = session, opts \\ []) do
    with :ok <- validate_session(mapping, session) do
      Transitions.resume(session, opts)
    end
  end

  @doc "Applies the public recovery transition after mapping validation."
  @spec recover_transition(session_mapping(), Data.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def recover_transition(mapping, %Data{} = session, opts \\ []) do
    with :ok <- validate_session(mapping, session) do
      Transitions.recover(session, opts)
    end
  end

  @doc "Applies the public checkpoint transition after mapping validation."
  @spec checkpoint_transition(session_mapping(), Data.t(), String.t(), Snapshot.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def checkpoint_transition(mapping, %Data{} = session, lease_id, %Snapshot{} = snapshot, opts \\ []) do
    with :ok <- validate_session(mapping, session) do
      Transitions.checkpoint(session, lease_id, snapshot, opts)
    end
  end

  @doc "Applies the public terminal commit transition after mapping validation."
  @spec commit_transition(session_mapping(), Data.t(), String.t(), Data.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def commit_transition(mapping, %Data{} = current, lease_id, %Data{} = completed, opts \\ []) do
    with :ok <- validate_session(mapping, current),
         :ok <- validate_session(mapping, completed) do
      Transitions.commit(current, lease_id, completed, opts)
    end
  end

  @doc "Applies the public lease-renewal transition after mapping validation."
  @spec renew_transition(session_mapping(), Data.t(), String.t(), keyword()) ::
          {:ok, Data.t()} | {:error, term()}
  def renew_transition(mapping, %Data{} = session, lease_id, opts \\ []) do
    with :ok <- validate_session(mapping, session) do
      Transitions.renew(session, lease_id, opts)
    end
  end

  @doc "Returns a stable Console checkpoint identity from committed Jidoka data."
  @spec checkpoint_identity(session_mapping(), Data.t(), Snapshot.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def checkpoint_identity(mapping, %Data{} = committed, %Snapshot{} = snapshot, opts \\ []) do
    with :ok <- validate_session(mapping, committed),
         {:ok, identity} <- Store.checkpoint_identity(committed, snapshot),
         {:ok, generation} <- generation_fields(mapping, opts) do
      {:ok,
       Map.merge(generation, %{
         console_session_id: mapping["console_session_id"],
         jidoka_session_id: identity.session_id,
         jidoka_revision: identity.durable_revision,
         jidoka_request_id: identity.request_id,
         jidoka_lease_id: identity.lease_id,
         jidoka_snapshot_id: identity.snapshot_id
       })}
    end
  end

  @doc "Returns bounded identity for the current public Jidoka recovery target."
  @spec recovery_identity(session_mapping(), Data.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def recovery_identity(mapping, session, opts \\ [])

  def recovery_identity(mapping, %Data{lease: %Lease{} = lease} = session, opts) do
    with :ok <- validate_session(mapping, session),
         {:ok, target} <- Data.recovery_target(session),
         {:ok, generation} <- generation_fields(mapping, opts) do
      {:ok,
       Map.merge(generation, %{
         console_session_id: mapping["console_session_id"],
         jidoka_session_id: session.session_id,
         jidoka_revision: session.revision,
         jidoka_request_id: lease.request_id,
         jidoka_lease_id: lease.lease_id,
         target: recovery_target_identity(target)
       })}
    end
  end

  def recovery_identity(mapping, %Data{} = session, _opts) do
    with :ok <- validate_session(mapping, session) do
      {:error, {:jidoka_session_not_recoverable, session.session_id}}
    end
  end

  @doc "Projects session, snapshot, event, and effect data without execution."
  @spec replay(session_mapping(), Data.t()) :: {:ok, Jidoka.Session.Replay.t()} | {:error, term()}
  def replay(mapping, %Data{} = session) do
    with :ok <- validate_session(mapping, session) do
      Jidoka.Session.replay(session)
    end
  end

  @doc "Returns explicit durable fork lineage identity."
  @spec fork_identity(session_mapping(), Data.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fork_identity(mapping, session, opts \\ [])

  def fork_identity(mapping, %Data{lineage: %Lineage{} = lineage} = session, opts) do
    with :ok <- validate_session(mapping, session),
         {:ok, generation} <- generation_fields(mapping, opts) do
      {:ok,
       Map.merge(generation, %{
         console_session_id: mapping["console_session_id"],
         jidoka_session_id: session.session_id,
         root_session_id: lineage.root_session_id,
         parent_session_id: lineage.parent_session_id,
         source_snapshot_id: lineage.source_snapshot_id,
         depth: lineage.depth
       })}
    end
  end

  def fork_identity(mapping, %Data{} = session, _opts) do
    with :ok <- validate_session(mapping, session) do
      {:error, {:jidoka_session_has_no_fork_lineage, session.session_id}}
    end
  end

  @doc "Forks through the public Jidoka facade and validates both mappings."
  @spec fork(session_mapping(), session_mapping(), keyword()) :: {:ok, Data.t()} | {:error, term()}
  def fork(source_mapping, child_mapping, opts \\ []) when is_list(opts) do
    with :ok <- validate_mapping_shape(source_mapping),
         :ok <- validate_mapping_rule(source_mapping),
         :ok <- validate_mapping_shape(child_mapping),
         :ok <- validate_mapping_rule(child_mapping),
         true <- child_mapping["kind"] == "forked" do
      source_id = source_mapping["jidoka_session_id"]
      child_id = child_mapping["jidoka_session_id"]

      case Jidoka.Session.fork(source_id, Keyword.put(opts, :session_id, child_id)) do
        {:ok, %Data{} = child} = result ->
          with :ok <- validate_session(child_mapping, child), do: result

        {:error, _reason} = error ->
          error
      end
    else
      false -> {:error, :forked_jidoka_session_mapping_required}
      {:error, _reason} = error -> error
    end
  end

  @doc "Validates one ordered Jidoka request stream."
  @spec validate_events([Event.t()]) :: :ok | {:error, term()}
  def validate_events(events), do: Order.validate(events)

  @doc "Projects events through the documented Jidoka root facade."
  @spec project_events([Event.t()] | Event.t()) :: {:ok, term()} | {:error, term()}
  def project_events(events), do: Jidoka.project_events(events)

  @doc "Returns the approved portable event names."
  @spec event_names() :: [atom()]
  def event_names, do: Event.events()

  @doc "Awaits a public Jidoka request handle."
  @spec await(term(), keyword()) :: term()
  def await(request, opts \\ []), do: Jidoka.await(request, opts)

  @doc "Cancels a public Jidoka request handle."
  @spec cancel(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def cancel(request, opts \\ []), do: Jidoka.cancel(request, opts)

  defp validate_mapping_shape(
         %{
           "console_session_id" => console_session_id,
           "jidoka_session_id" => jidoka_session_id,
           "kind" => kind
         } = mapping
       )
       when map_size(mapping) == 3 and is_binary(console_session_id) and
              is_binary(jidoka_session_id) and kind in @mapping_kinds do
    with {:ok, bounds} <- protocol_bounds(),
         :ok <- validate_identity(console_session_id, bounds) do
      validate_identity(jidoka_session_id, bounds)
    end
  end

  defp validate_mapping_shape(_mapping), do: {:error, :invalid_jidoka_session_mapping}

  defp mapping_kind(kind) when is_atom(kind), do: mapping_kind(Atom.to_string(kind))
  defp mapping_kind(kind) when kind in @mapping_kinds, do: {:ok, kind}
  defp mapping_kind(_kind), do: {:error, :invalid_jidoka_session_mapping}

  defp validate_mapping_rule(%{
         "kind" => "normal",
         "console_session_id" => session_id,
         "jidoka_session_id" => session_id
       }),
       do: :ok

  defp validate_mapping_rule(%{"kind" => kind}) when kind in ~w(imported forked), do: :ok

  defp validate_mapping_rule(mapping) do
    {:error, {:jidoka_session_mapping_mismatch, mapping["console_session_id"], mapping["jidoka_session_id"]}}
  end

  defp equal_jidoka_session(%{"jidoka_session_id" => session_id}, session_id), do: :ok

  defp equal_jidoka_session(mapping, actual) do
    {:error, {:jidoka_session_mapping_mismatch, mapping["jidoka_session_id"], actual}}
  end

  defp validate_optional_session(_mapping, nil), do: :ok
  defp validate_optional_session(mapping, %Data{} = session), do: validate_session(mapping, session)
  defp validate_optional_session(_mapping, _session), do: {:error, :invalid_jidoka_session_mapping}

  defp validate_receipt(%{"family" => "receipt", "type" => type}) when type != "client_output", do: :ok
  defp validate_receipt(_receipt), do: {:error, :invalid_console_receipt_metadata}

  defp validate_receipt_count(%{"payload" => payload}, bounds) do
    limit = bounds["max_unknown_keys"]

    if is_map(payload) and map_size(payload) <= limit,
      do: :ok,
      else: {:error, {:oversized_console_receipt_metadata, :keys, limit}}
  end

  defp validate_metadata_bytes(encoded, bounds) do
    limit = bounds["max_unknown_bytes"]

    if byte_size(encoded) <= limit,
      do: :ok,
      else: {:error, {:oversized_console_receipt_metadata, :bytes, byte_size(encoded), limit}}
  end

  defp validate_identity(value, bounds) do
    limit = bounds["max_identity_bytes"]

    cond do
      value == "" -> {:error, :invalid_jidoka_session_mapping}
      byte_size(value) > limit -> {:error, {:oversized_jidoka_session_identity, byte_size(value), limit}}
      true -> :ok
    end
  end

  defp protocol_bounds do
    with {:ok, schema} <- Protocol.schema(), do: Protocol.bounds(schema)
  end

  defp recovery_target_identity({:resume, %Snapshot{} = snapshot}) do
    %{kind: :resume, snapshot_id: snapshot.snapshot_id}
  end

  defp recovery_target_identity({:restart, %Turn.Request{} = request}) do
    %{kind: :restart, request_id: request.request_id}
  end

  defp generation_fields(mapping, opts) do
    case Keyword.get(opts, :console_fence) do
      nil ->
        {:ok, %{}}

      fence ->
        with :ok <- Generation.validate(fence),
             true <- fence.session_id == mapping["console_session_id"] do
          {:ok,
           %{
             console_generation: fence.generation,
             console_owner_instance_id: fence.owner_instance_id,
             console_operation_id: fence.operation_id
           }}
        else
          false -> {:error, :cross_session_generation_fence}
          {:error, _reason} = error -> error
        end
    end
  end
end
