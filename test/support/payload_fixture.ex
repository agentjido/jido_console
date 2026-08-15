defmodule Jido.Console.Release.PayloadFixture do
  @moduledoc false

  alias Jido.Console.Release.Payload

  @doc "Writes a sealed payload whose archive contains a runnable stub launcher."
  @spec create(Path.t(), keyword()) :: %{
          directory: Path.t(),
          archive: Path.t(),
          key: Payload.keypair(),
          version: String.t()
        }
  def create(directory, opts \\ []) do
    version = Keyword.get(opts, :version, "0.1.0")
    key = Keyword.get_lazy(opts, :keypair, &Payload.generate_key/0)
    archive_name = "jido-#{version}-darwin-arm64.tar.gz"
    archive = Path.join(directory, archive_name)
    staging = Path.join(directory, ".staging")
    launcher = Path.join(staging, "bin/jido")

    File.mkdir_p!(Path.dirname(launcher))
    File.write!(launcher, stub_launcher(version))
    File.chmod!(launcher, 0o755)

    :ok =
      :erl_tar.create(
        String.to_charlist(archive),
        [{~c"bin/jido", String.to_charlist(launcher)}],
        [:compressed]
      )

    File.write!(Path.join(directory, "LICENSE"), "Apache License Version 2.0")

    File.write!(
      Path.join(directory, "release.json"),
      Jason.encode!(%{"version" => version, "license" => "Apache-2.0", "target" => "darwin-arm64"}) <> "\n"
    )

    File.write!(Path.join(directory, "sbom.json"), "{}\n")
    File.write!(Path.join(directory, "provenance.json"), "{}\n")
    {:ok, _report} = Payload.seal(directory, archive: archive, keypair: key)

    %{directory: directory, archive: archive, key: key, version: version}
  end

  defp stub_launcher(version) do
    """
    #!/bin/sh
    echo "jido #{version}"
    """
  end
end
