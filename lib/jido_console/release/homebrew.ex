defmodule Jido.Console.Release.Homebrew do
  @moduledoc """
  Builds a Homebrew formula for the exact signed native payload.

  The formula does not compile Erlang or Elixir and does not download a
  replacement runtime. It is not published by this module.
  """

  alias Jido.Console.Release.Channel

  @revision 1

  @type install :: %{
          channel: :homebrew,
          root: String.t(),
          executable: String.t(),
          payload_identity: Channel.payload_identity(),
          owner_root: String.t(),
          formula_path: String.t(),
          formula_revision: pos_integer()
        }

  @doc "Returns the formula revision used for the v0.1 support claim."
  @spec revision() :: pos_integer()
  def revision, do: @revision

  @doc "Renders a formula that pins the payload archive and checksum."
  @spec formula(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def formula(payload_dir, opts \\ []) do
    archive = Keyword.get_lazy(opts, :archive, fn -> archive_name(payload_dir) end)

    with {:ok, release} <- decode(Path.join(payload_dir, "release.json")),
         {:ok, sha} <- Jido.Console.Release.Payload.checksum(payload_dir, archive) do
      {:ok,
       """
       class Jido < Formula
         desc "Jido Console local coding harness"
         homepage "https://github.com/agentjido/jido_console"
         url "file://#{archive}"
         version "#{release["version"]}"
         sha256 "#{sha}"
         license "#{release["license"] || "Apache-2.0"}"
         revision #{@revision}

         def install
           prefix.install Dir["*"]
         end
       end
       """}
    end
  end

  @doc "Executes and reports the Homebrew lifecycle."
  @spec lifecycle(Path.t(), Path.t(), keyword()) :: Channel.result()
  def lifecycle(payload_dir, prefix, opts \\ []) do
    Channel.execute(
      :homebrew,
      Channel.identity(payload_dir),
      fn ->
        case install(payload_dir, prefix, opts) do
          {:ok, install} ->
            evidence =
              Channel.install_evidence(install, "homebrew_formula", %{
                "formula_revision" => @revision,
                "formula" => Path.relative_to(install.formula_path, prefix),
                "cellar" => Path.relative_to(install.root, prefix)
              })

            {:ok, install, evidence}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      fn install ->
        case Channel.first_run(install) do
          {:ok, evidence} ->
            {:ok, Map.put(evidence, "formula_revision", @revision)}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      fn install ->
        case install(payload_dir, prefix, opts) do
          {:ok, updated} ->
            evidence =
              Channel.identity_evidence("update", updated.payload_identity, %{
                "method" => "homebrew_formula",
                "from_revision" => install.formula_revision,
                "to_revision" => updated.formula_revision
              })

            {:ok, updated, evidence}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      &remove/1
    )
  end

  @doc "Installs the formula and its verified payload into a Homebrew cellar."
  @spec install(Path.t(), Path.t(), keyword()) :: {:ok, install()} | {:error, term()}
  def install(payload_dir, prefix, opts \\ []) do
    with {:ok, text} <- formula(payload_dir, opts),
         :ok <- reject_build_steps(text),
         {:ok, identity} <- Channel.identity(payload_dir),
         cellar = Path.join(prefix, "Cellar/jido/#{identity["version"]}"),
         formula_path = Path.join(prefix, "Formula/jido.rb"),
         :ok <- write_formula(formula_path, text),
         {:ok, install} <- Channel.install_payload(:homebrew, payload_dir, cellar, opts) do
      {:ok,
       %{
         channel: :homebrew,
         root: install.root,
         executable: install.executable,
         payload_identity: install.payload_identity,
         owner_root: prefix,
         formula_path: formula_path,
         formula_revision: @revision
       }}
    end
  end

  @doc "Removes the formula and the owned Homebrew cellar."
  @spec remove(install()) :: {:ok, map()} | {:error, term()}
  def remove(install) do
    case File.rm_rf(install.owner_root) do
      {:ok, _files} ->
        {:ok,
         %{
           "stage" => "remove",
           "status" => "pass",
           "method" => "homebrew_uninstall",
           "formula_revision" => install.formula_revision,
           "root_exists" => File.exists?(install.owner_root)
         }}

      {:error, reason, path} ->
        {:error, {:homebrew_remove_failed, path, reason}}
    end
  end

  defp reject_build_steps(text) do
    if String.contains?(text, ["system \"mix", "system \"erl", "curl ", "wget "]) do
      {:error, :homebrew_builds_from_source}
    else
      :ok
    end
  end

  defp write_formula(path, text) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, text)
  end

  defp archive_name(directory) do
    case Path.wildcard(Path.join(directory, "*.tar.gz")) do
      [archive] -> Path.basename(archive)
      _other -> "missing.tar.gz"
    end
  end

  defp decode(path) do
    with {:ok, body} <- File.read(path), do: Jason.decode(body)
  end
end
