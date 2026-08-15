defmodule Jido.Console.Coding.Paths do
  @moduledoc """
  Normalizes restricted file paths and rejects root escape and symbolic-link escape.

  Access is allowed only when the resolved path stays inside a declared workspace,
  toolchain, artifact, or temporary root.
  """

  @type decision :: %{
          outcome: :allow | :deny,
          root: String.t() | nil,
          reason: String.t()
        }

  @doc "Returns an allow or deny decision for one path against declared roots."
  @spec check(String.t(), [String.t()], keyword()) :: {:ok, decision()} | {:error, term()}
  def check(path, roots, opts \\ []) when is_binary(path) and is_list(roots) do
    if roots == [] do
      {:error, :missing_declared_roots}
    else
      {:ok, decide(path, roots, opts)}
    end
  end

  defp decide(path, roots, _opts) do
    requested = Path.expand(path)

    with {:ok, resolved_roots} <- resolve_all(roots),
         {:ok, resolved} <- resolve(requested) do
      case inside_root(resolved, resolved_roots) do
        nil ->
          reason =
            if requested != resolved,
              do: "symbolic-link escape",
              else: "path is outside declared roots"

          deny(reason)

        root ->
          allow(root)
      end
    else
      {:error, :symlink_cycle} -> deny("symbolic-link escape")
    end
  end

  defp inside_root(path, roots) do
    Enum.find(roots, fn root ->
      path == root or String.starts_with?(path, root <> "/")
    end)
  end

  defp resolve_all(roots) do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, acc} ->
      case resolve(Path.expand(root)) do
        {:ok, resolved} -> {:cont, {:ok, acc ++ [resolved]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp resolve(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while({:ok, "/"}, fn
      "/", {:ok, acc} ->
        {:cont, {:ok, acc}}

      part, {:ok, acc} ->
        case follow(Path.join(acc, part), %{}) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, _reason} = error -> {:halt, error}
        end
    end)
  end

  defp follow(path, seen) when is_map(seen) do
    if Map.has_key?(seen, path) do
      {:error, :symlink_cycle}
    else
      case File.read_link(path) do
        {:ok, target} ->
          target =
            if Path.type(target) == :absolute,
              do: Path.expand(target),
              else: Path.expand(target, Path.dirname(path))

          follow(target, Map.put(seen, path, true))

        {:error, _reason} ->
          {:ok, path}
      end
    end
  end

  defp allow(root), do: %{outcome: :allow, root: root, reason: "inside declared root"}
  defp deny(reason), do: %{outcome: :deny, root: nil, reason: reason}
end
