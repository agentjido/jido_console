defmodule Jido.Console.Process.Contract do
  @moduledoc "Defines the owned-process catalog and public record types."

  @statuses [:starting, :ready, :running, :stopping, :stopped, :failed]
  @catalog %{
    interactive: %{
      name: "interactive",
      owner: "tui",
      purpose: "interactive terminal session",
      readiness: "terminal and runtime are ready",
      shutdown: "TUI shutdown through the process supervisor"
    },
    coding_runtime: %{
      name: "coding-runtime",
      owner: "coding",
      purpose: "trusted local coding manager",
      readiness: "execution manager is open",
      shutdown: "coding setup close through the process supervisor"
    }
  }

  @type status :: :starting | :ready | :running | :stopping | :stopped | :failed
  @type kind :: :interactive | :coding_runtime
  @type identity :: {kind(), String.t()}
  @type process_record :: %{
          required(:kind) => kind(),
          required(:name) => String.t(),
          required(:owner) => String.t(),
          required(:status) => status(),
          required(:readiness) => String.t(),
          optional(:failure) => String.t() | nil
        }
  @type live_record :: %{
          required(:kind) => kind(),
          required(:name) => String.t(),
          required(:owner) => String.t(),
          required(:status) => status(),
          required(:readiness) => String.t(),
          required(:failure) => String.t() | nil,
          required(:owner_pid) => pid() | nil,
          required(:owner_os_pid) => pos_integer() | nil
        }

  @public_fields [:kind, :name, :owner, :status, :readiness, :failure]
  @stored_fields [:kind, :name, :status, :readiness, :failure, :owner_os_pid]

  @doc "Returns the supported process status values."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Returns the local process ownership and status matrix."
  @spec catalog() :: %{kind() => map()}
  def catalog, do: @catalog

  @doc "Returns one catalog entry."
  @spec spec(kind()) :: map()
  def spec(kind) when is_map_key(@catalog, kind), do: Map.fetch!(@catalog, kind)

  @doc "Returns the one catalog-owned identity for a process kind."
  @spec identity(kind()) :: identity()
  def identity(kind) when is_map_key(@catalog, kind) do
    {kind, spec(kind).name}
  end

  @doc "Resolves a contract name to its catalog-owned identity."
  @spec identity_for_name(String.t()) :: {:ok, identity()} | {:error, :unknown_process_name}
  def identity_for_name(name) when is_binary(name) do
    case Enum.find(@catalog, fn {_kind, entry} -> entry.name == name end) do
      {kind, _entry} -> {:ok, identity(kind)}
      nil -> {:error, :unknown_process_name}
    end
  end

  @doc "Returns the catalog name from a canonical process identity."
  @spec name(identity()) :: String.t()
  def name({_kind, name}), do: name

  @doc "Builds a validated live process record from catalog-owned data."
  @spec live(kind(), pid(), pos_integer() | nil) :: live_record()
  def live(kind, owner_pid, owner_os_pid) when is_pid(owner_pid) do
    entry = spec(kind)

    %{
      kind: kind,
      name: entry.name,
      owner: entry.owner,
      status: :ready,
      readiness: entry.readiness,
      failure: nil,
      owner_pid: owner_pid,
      owner_os_pid: owner_os_pid
    }
  end

  @doc "Restores and validates a live record from its stored projection."
  @spec restore(map()) :: {:ok, live_record()} | {:error, :invalid_process_marker}
  def restore(stored) when is_map(stored) do
    with kind when is_map_key(@catalog, kind) <- stored[:kind],
         {^kind, expected_name} <- identity(kind),
         ^expected_name <- stored[:name],
         status when status in @statuses <- stored[:status],
         readiness when is_binary(readiness) <- stored[:readiness],
         failure when is_binary(failure) or is_nil(failure) <- stored[:failure],
         owner_os_pid when (is_integer(owner_os_pid) and owner_os_pid > 1) or is_nil(owner_os_pid) <-
           stored[:owner_os_pid] do
      entry = spec(kind)

      {:ok,
       %{
         kind: kind,
         name: expected_name,
         owner: entry.owner,
         status: status,
         readiness: readiness,
         failure: failure,
         owner_pid: nil,
         owner_os_pid: owner_os_pid
       }}
    else
      _invalid -> {:error, :invalid_process_marker}
    end
  end

  def restore(_other), do: {:error, :invalid_process_marker}

  @doc "Returns the canonical identity of a validated record."
  @spec key(map()) :: identity()
  def key(%{kind: kind, name: name}) when is_map_key(@catalog, kind) do
    {^kind, ^name} = identity(kind)
  end

  @doc "Projects a live record for persistent storage."
  @spec stored(map()) :: map()
  def stored(record) do
    key(record)
    Map.take(record, @stored_fields)
  end

  @doc "Projects a live or stored record for public output."
  @spec public(map()) :: process_record()
  def public(record) do
    key(record)
    Map.take(record, @public_fields)
  end
end
