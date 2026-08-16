defmodule Jido.Console.Session.Drain do
  @moduledoc """
  Exact queued and active worker drain tracking.
  """

  @states [:queued, :active, :draining, :drained, :failed]

  @type item :: %{
          identity: map(),
          status: atom(),
          descendants: [String.t()]
        }

  @type t :: %{items: %{String.t() => item()}}

  @doc "Returns an empty drain registry."
  @spec new() :: t()
  def new, do: %{items: %{}}

  @doc "Tracks one queued work item."
  @spec queue(t(), map()) :: t()
  def queue(drain, identity) do
    put(drain, identity, :queued, [])
  end

  @doc "Marks work active with owned descendant identities."
  @spec activate(t(), map(), [String.t()]) :: t()
  def activate(drain, identity, descendants \\ []) do
    put(drain, identity, :active, descendants)
  end

  @doc "Starts drain for one work item."
  @spec start(t(), map()) :: t()
  def start(drain, identity), do: put(drain, identity, :draining, descendants(drain, identity))

  @doc "Records that one worker or descendant has stopped."
  @spec collect(t(), map(), String.t()) :: {:ok, t()} | {:error, term()}
  def collect(drain, identity, worker_id) do
    item = drain.items[identity.id]

    cond do
      is_nil(item) ->
        {:error, :unknown_work}

      item.identity.session_id != identity.session_id ->
        {:error, :cross_session_result}

      worker_id != identity.id and worker_id not in item.descendants ->
        {:error, :unknown_descendant}

      true ->
        descendants = List.delete(item.descendants, worker_id)
        status = if descendants == [] and worker_id == identity.id, do: :drained, else: item.status
        items = Map.put(drain.items, identity.id, %{item | descendants: descendants, status: status})
        {:ok, %{drain | items: items}}
    end
  end

  @doc "Completes drain only when every owned worker is accounted for."
  @spec complete?(t()) :: boolean()
  def complete?(drain) do
    Enum.all?(drain.items, fn {_id, item} -> item.status in [:drained, :failed] end)
  end

  @doc "Fails drain when a descendant is missing."
  @spec fail(t(), map()) :: t()
  def fail(drain, identity), do: put(drain, identity, :failed, descendants(drain, identity))

  defp put(drain, identity, status, descendants) when status in @states do
    %{
      drain
      | items:
          Map.put(drain.items, identity.id, %{
            identity: identity,
            status: status,
            descendants: descendants
          })
    }
  end

  defp descendants(drain, identity) do
    case drain.items[identity.id] do
      nil -> []
      item -> item.descendants
    end
  end
end
