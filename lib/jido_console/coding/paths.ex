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

  defp decide(path, roots, opts) do
    resolved_roots = Enum.map(roots, &resolve(Path.expand(&1)))
    resolved = resolve(Path.expand(path))
    _opts = opts

    case inside_root(resolved, resolved_roots) do
      nil ->
        reason =
          if symlink_escape?(Path.expand(path), resolved, resolved_roots),
            do: "symbolic-link escape",
            else: "path is outside declared roots"

        deny(reason)

      root ->
        allow(root)
    end
  end

  defp symlink_escape?(requested, resolved, roots) do
    requested != resolved and is_nil(inside_root(resolved, roots))
  end

  defp inside_root(path, roots) do
    Enum.find(roots, fn root ->
      path == root or String.starts_with?(path, root <> "/")
    end)
  end

  defp resolve(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn
      "/", acc -> acc
      part, acc -> follow(Path.join(acc, part))
    end)
  end

  defp follow(path) do
    case File.read_link(path) do
      {:ok, target} ->
        target =
          if Path.type(target) == :absolute,
            do: Path.expand(target),
            else: Path.expand(target, Path.dirname(path))

        follow(target)

      {:error, _reason} ->
        path
    end
  end

  defp allow(root), do: %{outcome: :allow, root: root, reason: "inside declared root"}
  defp deny(reason), do: %{outcome: :deny, root: nil, reason: reason}
end
