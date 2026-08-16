defmodule Jido.Console.Session.Registry do
  @moduledoc """
  Named session registry that does not create atoms from untrusted IDs.
  """

  @doc "Child spec for the session registry."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {Registry, :start_link, [[keys: :unique, name: name]]},
      type: :supervisor
    }
  end

  @doc "Returns a via tuple for a session ID."
  @spec via(String.t(), atom()) :: {:via, Registry, {atom(), String.t()}}
  def via(session_id, registry \\ __MODULE__) when is_binary(session_id) do
    {:via, Registry, {registry, session_id}}
  end

  @doc "Looks up one session server by ID."
  @spec lookup(String.t(), atom()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(session_id, registry \\ __MODULE__) when is_binary(session_id) do
    case Registry.lookup(registry, session_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  catch
    :exit, {:noproc, _info} -> {:error, :not_found}
  end
end
