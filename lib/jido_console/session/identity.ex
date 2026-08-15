defmodule Jido.Console.Session.Identity do
  @moduledoc """
  Process-lifetime identities for live session work.

  Identities are bounded protocol-safe tokens bound to one application
  lifetime and one session. They do not survive an application restart and
  never carry credential values.
  """

  @kinds %{
    session: "ses",
    action: "act",
    turn: "trn",
    lane: "lan",
    step: "stp",
    request: "req",
    run: "run",
    worker: "wrk",
    approval: "apr",
    control: "ctl",
    client: "cli",
    input: "inp",
    attachment: "att",
    command: "cmd",
    invocation: "inv"
  }

  @max_bytes 256
  @token_bytes 10

  @type kind ::
          :session
          | :action
          | :turn
          | :lane
          | :step
          | :request
          | :run
          | :worker
          | :approval
          | :control
          | :client
          | :input
          | :attachment
          | :command
          | :invocation

  @type t :: %{
          required(:kind) => kind(),
          required(:id) => String.t(),
          required(:session_id) => String.t(),
          required(:generation) => pos_integer(),
          optional(:owner) => String.t()
        }

  @doc "Returns the supported identity kinds and prefixes."
  @spec kinds() :: %{kind() => String.t()}
  def kinds, do: @kinds

  @doc "Creates a process-lifetime identity bound to a session."
  @spec new(kind(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(kind, opts \\ []) do
    with {:ok, prefix} <- fetch_prefix(kind),
         :ok <- reject_credentials(opts),
         {:ok, session_id} <- session_id(kind, opts),
         id = Keyword.get_lazy(opts, :id, fn -> generate(kind, prefix) end),
         :ok <- validate_id(id, kind) do
      {:ok,
       %{
         kind: kind,
         id: id,
         session_id: if(kind == :session, do: id, else: session_id),
         generation: Keyword.get(opts, :generation, 1),
         owner: Keyword.get(opts, :owner, owner_for(kind))
       }}
    end
  end

  @doc "Creates a process-lifetime identity or raises."
  @spec new!(kind(), keyword()) :: t()
  def new!(kind, opts \\ []) do
    case new(kind, opts) do
      {:ok, identity} -> identity
      {:error, reason} -> raise ArgumentError, "invalid identity: #{inspect(reason)}"
    end
  end

  @doc "Returns the default owner for a kind."
  @spec owner_for(kind()) :: String.t()
  def owner_for(:session), do: "application"
  def owner_for(:client), do: "client"
  def owner_for(:attachment), do: "client"
  def owner_for(_kind), do: "session"

  @doc "Validates that an identity string matches its kind and bound."
  @spec validate_id(String.t(), kind()) :: :ok | {:error, term()}
  def validate_id(id, kind) when is_binary(id) do
    prefix = Map.fetch!(@kinds, kind)

    cond do
      byte_size(id) > @max_bytes ->
        {:error, {:identity_too_large, kind}}

      not String.starts_with?(id, prefix <> "_") ->
        {:error, {:identity_prefix_invalid, kind}}

      String.contains?(id, ["token", "secret", "password", "credential"]) ->
        {:error, :credential_in_identity}

      true ->
        :ok
    end
  end

  def validate_id(_id, kind), do: {:error, {:identity_invalid, kind}}

  @doc "Returns true when two identities name the same live work item."
  @spec same?(t(), t()) :: boolean()
  def same?(left, right) do
    left.kind == right.kind and left.id == right.id and left.session_id == right.session_id and
      left.generation == right.generation
  end

  @doc "Returns true when a result identity belongs to another session."
  @spec cross_session?(t(), t()) :: boolean()
  def cross_session?(live, candidate), do: live.session_id != candidate.session_id

  @doc "Returns true when a result identity is from an earlier generation."
  @spec stale?(t(), t()) :: boolean()
  def stale?(live, candidate) do
    live.session_id == candidate.session_id and candidate.generation < live.generation
  end

  @doc "Rejects host, origin, or transport as an authority source."
  @spec authority_source?(term()) :: boolean()
  def authority_source?(source) when source in [:host, :origin, :transport, "host", "origin", "transport"],
    do: true

  def authority_source?(_source), do: false

  @doc "Keeps identity data protocol-safe."
  @spec to_protocol(t()) :: map()
  def to_protocol(identity) do
    %{
      "kind" => Atom.to_string(identity.kind),
      "id" => identity.id,
      "session_id" => identity.session_id,
      "generation" => identity.generation,
      "owner" => identity.owner
    }
  end

  defp session_id(:session, opts) do
    {:ok, Keyword.get_lazy(opts, :session_id, fn -> generate(:session) end)}
  end

  defp session_id(_kind, opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) ->
        with :ok <- validate_id(session_id, :session), do: {:ok, session_id}

      _other ->
        {:error, :session_id_missing}
    end
  end

  defp fetch_prefix(kind) do
    case Map.fetch(@kinds, kind) do
      {:ok, prefix} -> {:ok, prefix}
      :error -> {:error, {:unknown_identity_kind, kind}}
    end
  end

  defp generate(kind, prefix \\ nil) do
    prefix = prefix || Map.fetch!(@kinds, kind)
    token = @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{prefix}_#{token}"
  end

  defp reject_credentials(opts) do
    if Keyword.has_key?(opts, :credential) or Keyword.has_key?(opts, :token) or
         Keyword.has_key?(opts, :password) do
      {:error, :credential_in_identity}
    else
      :ok
    end
  end
end
