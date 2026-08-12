defmodule Jido.Cli.Extensions.Trust do
  @moduledoc "Canonical project identity and non-interactive extension trust checks."

  @doc "Returns a canonical project identity with an injectable repository identity."
  @spec project_identity(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def project_identity(root, opts \\ []) when is_binary(root) do
    with {:ok, canonical_root} <- canonical_path(root),
         {:ok, repository_id} <- repository_id(canonical_root, opts) do
      {:ok, %{root: canonical_root, repository_id: repository_id}}
    end
  end

  @doc "Loads and validates trust for the current project."
  @spec trusted_extensions(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def trusted_extensions(identity, opts) do
    case Keyword.get(opts, :extension_trust_file) || Application.get_env(:jido_cli, :extension_trust_file) do
      nil -> {:error, {:untrusted_extension_project, identity.root, identity.repository_id}}
      path -> load_trust(path, identity)
    end
  end

  defp load_trust(path, identity) do
    with {:ok, document} <- decode(path),
         1 <- Map.get(document, "version", 1),
         projects when is_list(projects) <- Map.get(document, "projects", []),
         {:ok, project} <- find_project(projects, identity),
         extensions when is_map(extensions) <- Map.get(project, "extensions", %{}) do
      {:ok, extensions}
    else
      reason -> {:error, {:invalid_extension_trust, path, reason}}
    end
  end

  defp find_project(projects, identity) do
    matches =
      Enum.filter(projects, fn project ->
        expanded = project |> Map.get("root", "") |> Path.expand()

        case canonical_path(expanded) do
          {:ok, root} ->
            root == identity.root and
              Map.get(project, "repository_id", identity.repository_id) == identity.repository_id

          {:error, _reason} ->
            false
        end
      end)

    case matches do
      [project] -> {:ok, project}
      [] -> {:error, :project_not_trusted}
      _projects -> {:error, :duplicate_project_trust}
    end
  end

  defp repository_id(root, opts) do
    case Keyword.get(opts, :repository_identity) do
      function when is_function(function, 1) -> function.(root)
      _function -> {:ok, default_repository_id(root)}
    end
  end

  defp default_repository_id(root) do
    git = Path.join(root, ".git")
    source = if File.exists?(git), do: canonical_path(git) |> elem_or(git), else: root
    "sha256:" <> (:crypto.hash(:sha256, source) |> Base.encode16(case: :lower))
  end

  defp elem_or({:ok, value}, _default), do: value
  defp elem_or(_error, default), do: default

  @doc "Resolves an existing path without invoking a shell command."
  @spec canonical_path(String.t()) :: {:ok, String.t()} | {:error, term()}
  def canonical_path(path) when is_binary(path) do
    path = Path.expand(path)

    with {:ok, _stat} <- File.stat(path),
         {:ok, resolved} <- resolve_path(path, 0) do
      {:ok, resolved}
    end
  end

  defp resolve_path(_path, count) when count > 32, do: {:error, :too_many_symbolic_links}

  defp resolve_path(path, count) do
    [root | parts] = Path.split(Path.expand(path))
    walk_path(root, parts, count)
  end

  defp walk_path(current, [], _count), do: {:ok, current}

  defp walk_path(current, [part | rest], count) do
    candidate = Path.join(current, part)

    case File.read_link(candidate) do
      {:ok, target} ->
        target = if Path.type(target) == :absolute, do: target, else: Path.expand(target, Path.dirname(candidate))
        resolve_path(Path.join([target | rest]), count + 1)

      {:error, :einval} ->
        walk_path(candidate, rest, count)

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(path) do
    with {:ok, contents} <- File.read(path) do
      case Path.extname(path) do
        ".json" -> Jason.decode(contents)
        _extension -> YamlElixir.read_from_string(contents, merge_anchors: false)
      end
    end
  end
end
