defmodule Jido.Console.Coding.Run do
  @moduledoc """
  Records a current-run workspace snapshot, reviews effects, and reverts them.

  Approval is required before an effect is applied. Rejection leaves the
  workspace unchanged. Revert restores only this run's applied paths.
  """

  alias Jido.Console.Coding.{Approval, Paths}
  alias Jido.Console.Digest
  alias Jido.Console.Providers.Redaction

  @type t :: %{
          id: String.t(),
          root: String.t(),
          snapshot: %{String.t() => map()},
          applied: [map()],
          rejected: [map()],
          context: map(),
          status: :open | :reverted | :failed
        }

  @doc "Opens a current run and records the pre-run workspace snapshot."
  @spec open(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(root, opts \\ []) when is_binary(root) do
    with {:ok, snapshot} <- snapshot(root) do
      id = Keyword.get(opts, :run_id, random_id())

      {:ok,
       %{
         id: id,
         root: root,
         snapshot: snapshot,
         applied: [],
         rejected: [],
         context: context(root, Keyword.put(opts, :run_id, id)),
         status: :open
       }}
    end
  end

  @doc "Returns a digest-only pre-run manifest."
  @spec manifest(t()) :: map()
  def manifest(run) do
    files =
      run.snapshot
      |> Enum.sort_by(&elem(&1, 0))
      |> Map.new(fn {path, record} -> {path, record.sha256} end)

    %{"run_id" => run.id, "files" => files}
  end

  @doc "Formats the proposed effects for review."
  @spec review([map()]) :: {:ok, String.t()} | {:error, term()}
  def review(effects) when is_list(effects) do
    effects
    |> Enum.reduce_while([], fn effect, acc ->
      case Approval.normalize(effect) do
        {:ok, normalized} -> {:cont, [normalized | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      normalized -> {:ok, format_review(Enum.reverse(normalized))}
    end
  end

  @doc "Records a rejected effect without changing the workspace."
  @spec reject(t(), map()) :: {:ok, t()} | {:error, term()}
  def reject(%{status: :open} = run, effect) do
    with {:ok, normalized} <- Approval.normalize(effect) do
      {:ok, %{run | rejected: run.rejected ++ [normalized]}}
    end
  end

  def reject(_run, _effect), do: {:error, :run_closed}

  @doc "Applies one approved effect inside the declared file roots."
  @spec apply_effect(t(), map(), map(), keyword()) :: {:ok, t(), map()} | {:error, term()}
  def apply_effect(run, effect, binding, opts \\ [])

  def apply_effect(%{status: :open} = run, effect, binding, opts) do
    with {:ok, normalized} <- Approval.normalize(effect),
         {:ok, _binding} <- Approval.authorize(binding, effect, run.context),
         {:ok, decision} <- Paths.check(absolute(run.root, normalized.path), roots(run, opts)),
         :ok <- allowed(decision),
         :ok <- write_effect(run, normalized),
         {:ok, _binding} <- Approval.consume(binding, :completed) do
      record = %{
        path: normalized.path,
        operation: normalized.operation,
        before: snapshot_digest(run, normalized.path),
        after: file_digest(run, normalized.path)
      }

      {:ok, %{run | applied: run.applied ++ [record]}, record}
    end
  end

  def apply_effect(_run, _effect, _binding, _opts), do: {:error, :run_closed}

  @doc "Restores current-run applied paths and leaves unrelated files alone."
  @spec revert(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def revert(run, opts \\ [])

  def revert(%{status: status} = run, opts) when status in [:open, :failed] do
    writer = Keyword.get(opts, :write, &File.write/2)
    remover = Keyword.get(opts, :rm, &File.rm/1)

    case restore_applied(run, writer, remover) do
      :ok -> {:ok, %{run | applied: [], status: :reverted}}
      {:error, failed} -> {:error, {:incomplete_revert, %{run | status: :failed}, failed}}
    end
  end

  def revert(%{status: :reverted}, _opts), do: {:error, :run_already_reverted}

  defp snapshot(root) do
    case File.ls(root) do
      {:ok, _entries} ->
        files =
          root
          |> Path.join("**/*")
          |> Path.wildcard(match_dot: true)
          |> Enum.filter(&File.regular?/1)

        Enum.reduce_while(files, {:ok, %{}}, fn path, {:ok, acc} ->
          case snapshot_file(root, path) do
            {:ok, {rel, record}} -> {:cont, {:ok, Map.put(acc, rel, record)}}
            {:error, reason} -> {:halt, {:error, {:snapshot_failed, reason}}}
          end
        end)

      {:error, reason} ->
        {:error, {:snapshot_failed, reason}}
    end
  end

  defp snapshot_file(root, path) do
    rel = Path.relative_to(path, root)

    case File.read(path) do
      {:ok, content} -> {:ok, {rel, %{sha256: Digest.hex(content), content: content}}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_effect(run, effect) do
    path = absolute(run.root, effect.path)
    content = Map.get(effect.params, "new_text") || Map.get(effect.params, "contents") || ""

    path
    |> Path.dirname()
    |> File.mkdir_p()
    |> case do
      :ok -> File.write(path, content)
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_applied(run, writer, remover) do
    run.applied
    |> Enum.reduce_while(:ok, fn record, :ok ->
      case restore_one(run, record, writer, remover) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, [{record.path, reason}]}}
      end
    end)
  end

  defp restore_one(run, record, writer, remover) do
    path = absolute(run.root, record.path)

    case Map.fetch(run.snapshot, record.path) do
      {:ok, %{content: content}} -> writer.(path, content)
      :error -> remover.(path)
    end
  end

  defp allowed(%{outcome: :allow}), do: :ok
  defp allowed(%{outcome: :deny}), do: {:error, :path_boundary_denied}

  defp roots(run, opts) do
    Keyword.get(opts, :roots, [run.root])
  end

  defp context(root, opts) do
    %{
      workspace: Keyword.get(opts, :workspace, digest(root)),
      run_id: Keyword.get(opts, :run_id, "run"),
      profile_id: Keyword.get(opts, :profile_id, "coding.restricted"),
      roots: %{"workspace" => "declared"},
      network_policy: Keyword.get(opts, :network_policy, "jido.network.v1"),
      process_owner: Keyword.get(opts, :process_owner, "coding")
    }
  end

  defp format_review(effects) do
    Enum.map_join(effects, "", fn effect ->
      params =
        effect.params
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map_join("\n", fn {key, value} -> "  #{key}: #{inspect(value)}" end)

      Redaction.redact("effect: #{effect.operation} #{Approval.display_path(effect.path)}\n#{params}\n")
    end)
  end

  defp snapshot_digest(run, path) do
    case Map.fetch(run.snapshot, path) do
      {:ok, record} -> record.sha256
      :error -> nil
    end
  end

  defp file_digest(run, path) do
    case File.read(absolute(run.root, path)) do
      {:ok, content} -> digest(content)
      {:error, _reason} -> nil
    end
  end

  defp absolute(root, path), do: Path.expand(path, root)

  defp digest(value), do: Digest.hex(value)

  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
