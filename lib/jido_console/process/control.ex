defmodule Jido.Console.Process.Control do
  @moduledoc "Lock-independent control path for stored Jido process owners."

  alias Jido.Console.Process.{Contract, Store, Tree}

  @doc "Stops one stored owner without starting the Jido application."
  @spec stop(String.t(), keyword()) :: {:ok, Contract.process_record()} | {:error, term()}
  def stop(name, opts \\ []) when is_binary(name) do
    with {:ok, identity} <- Contract.identity_for_name(name) do
      case Store.get(identity, opts) do
        {:ok, record} -> stop_record(record, opts)
        {:error, :process_not_found} -> {:ok, already_stopped(identity)}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc "Stops all stored owners without starting the Jido application."
  @spec stop_all(keyword()) :: {:ok, [Contract.process_record()]} | {:error, term()}
  def stop_all(opts \\ []) do
    with {:ok, records} <- Store.list(opts) do
      Enum.reduce_while(records, {:ok, []}, fn record, {:ok, stopped} ->
        case stop_record(record, opts) do
          {:ok, result} -> {:cont, {:ok, [result | stopped]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, stopped} -> {:ok, Enum.reverse(stopped)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp stop_record(%{owner_os_pid: os_pid} = record, opts)
       when is_integer(os_pid) and os_pid > 1 do
    cond do
      os_pid == beam_os_pid() ->
        {:error, :process_control_owner_is_current_runtime}

      Tree.alive?(os_pid) ->
        with {:ok, _result} <- Tree.stop(os_pid),
             :ok <- Store.delete(Contract.key(record), opts) do
          {:ok, stopped(record)}
        end

      true ->
        with :ok <- Store.delete(Contract.key(record), opts) do
          {:ok, stopped(record)}
        end
    end
  end

  defp stop_record(record, opts) do
    with :ok <- Store.delete(Contract.key(record), opts) do
      {:ok, stopped(record)}
    end
  end

  defp stopped(record) do
    record
    |> Map.merge(%{status: :stopped, readiness: "stopped", failure: nil})
    |> Contract.public()
  end

  defp already_stopped({kind, name}) do
    spec = Contract.spec(kind)

    %{
      kind: kind,
      name: name,
      owner: spec.owner,
      status: :stopped,
      readiness: "already stopped",
      failure: nil
    }
  end

  defp beam_os_pid do
    case Integer.parse(System.pid()) do
      {pid, ""} when pid > 1 -> pid
      _invalid -> nil
    end
  end
end
