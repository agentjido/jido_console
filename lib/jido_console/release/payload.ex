defmodule Jido.Console.Release.Payload do
  @moduledoc """
  Signs and verifies the macOS ARM64 native payload and its evidence files.

  This module does not publish an archive, Homebrew formula, or npm package.
  """

  alias Jido.Console.Providers.Redaction
  alias Jido.Console.Release.Identity

  @evidence ~w(release.json sbom.json provenance.json)
  @algorithm "eddsa-ed25519"

  @type keypair :: %{public: binary(), private: binary()}
  @type report :: map()

  @doc "Generates one Ed25519 key pair for local signing tests."
  @spec generate_key() :: keypair()
  def generate_key do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: public, private: private}
  end

  @doc "Reads one named SHA-256 from checksums.txt."
  @spec checksum(Path.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def checksum(directory, name) when is_binary(directory) and is_binary(name) do
    with {:ok, body} <- File.read(Path.join(directory, "checksums.txt")) do
      case checksum_line(body, &(&1 == name)) do
        nil -> {:error, :archive_checksum_missing}
        sha -> {:ok, sha}
      end
    end
  end

  @doc "Reads the first archive SHA-256 from checksums.txt."
  @spec archive_checksum(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def archive_checksum(directory) when is_binary(directory) do
    with {:ok, body} <- File.read(Path.join(directory, "checksums.txt")) do
      case checksum_line(body, &String.ends_with?(&1, ".tar.gz")) do
        nil -> {:error, :archive_checksum_missing}
        sha -> {:ok, sha}
      end
    end
  end

  @doc "Writes checksums for the archive and required evidence files."
  @spec checksums(Path.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def checksums(directory, names) when is_binary(directory) and is_list(names) do
    names
    |> Enum.reduce_while([], fn name, acc ->
      path = Path.join(directory, name)

      if File.regular?(path) do
        {:cont, ["#{sha256_file(path)}  #{name}\n" | acc]}
      else
        {:halt, {:error, {:missing_release_file, name}}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      lines -> {:ok, lines |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  @doc "Seals one candidate directory with checksums and a signature."
  @spec seal(Path.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def seal(directory, opts \\ []) when is_binary(directory) do
    archive = Keyword.get_lazy(opts, :archive, fn -> find_archive(directory) end)
    key = Keyword.get_lazy(opts, :keypair, &generate_key/0)

    with {:ok, archive} <- archive_name(archive),
         {:ok, body} <- checksums(directory, [archive | @evidence]),
         :ok <- File.write(Path.join(directory, "checksums.txt"), body),
         signature <- sign(body, key.private),
         record <- evidence_record(directory, archive, key.public, signature),
         :ok <- File.write(Path.join(directory, "payload.sig"), signature),
         :ok <- write_json(Path.join(directory, "payload.json"), record) do
      {:ok, verify_report(directory, record, :ok)}
    end
  end

  @doc "Verifies checksums and the signature, and fails for a changed payload."
  @spec verify(Path.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def verify(directory, opts \\ []) when is_binary(directory) do
    public = Keyword.get(opts, :public_key)
    checksums_path = Path.join(directory, "checksums.txt")
    signature_path = Path.join(directory, "payload.sig")
    payload_path = Path.join(directory, "payload.json")

    with {:ok, body} <- File.read(checksums_path),
         {:ok, signature} <- File.read(signature_path),
         {:ok, record} <- read_json(payload_path),
         :ok <- verify_version(directory, record),
         :ok <- verify_checksums(directory, body),
         :ok <- verify_signature(body, signature, public || decode_key(record["public_key"])) do
      {:ok, verify_report(directory, record, :ok)}
    end
  end

  @doc "Compares two sealed evidence sets and lists only documented differences."
  @spec compare(report(), report()) :: {:ok, map()} | {:error, term()}
  def compare(left, right) when is_map(left) and is_map(right) do
    allowed = ["sealed_at"]
    left_map = Map.drop(left, allowed)
    right_map = Map.drop(right, allowed)

    if left_map == right_map do
      {:ok, %{"status" => "same", "allowed_differences" => allowed}}
    else
      changed =
        (Map.keys(left_map) ++ Map.keys(right_map))
        |> Enum.uniq()
        |> Enum.reject(&(left_map[&1] == right_map[&1]))

      {:error, {:payload_mismatch, changed}}
    end
  end

  defp sign(data, private) do
    :crypto.sign(:eddsa, :none, data, [private, :ed25519]) |> Base.encode64()
  end

  defp verify_signature(data, signature, public) do
    decoded = Base.decode64!(signature)

    if :crypto.verify(:eddsa, :none, data, decoded, [public, :ed25519]) do
      :ok
    else
      {:error, :payload_signature_invalid}
    end
  rescue
    _exception -> {:error, :payload_signature_invalid}
  end

  defp verify_checksums(directory, body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while(:ok, fn line, :ok ->
      case String.split(line, "  ", parts: 2) do
        [expected, name] ->
          path = Path.join(directory, name)

          if File.regular?(path) and sha256_file(path) == expected do
            {:cont, :ok}
          else
            {:halt, {:error, {:checksum_mismatch, name}}}
          end

        _other ->
          {:halt, {:error, :checksum_malformed}}
      end
    end)
  end

  defp verify_version(directory, record) do
    release = read_json!(Path.join(directory, "release.json"))
    license = File.read!(Path.join(directory, license_path(directory)))

    cond do
      release["version"] != record["version"] ->
        {:error, :version_mismatch}

      not String.contains?(license, "Apache") and not String.contains?(license, "MIT") ->
        {:error, :license_mismatch}

      true ->
        :ok
    end
  rescue
    _exception -> {:error, :version_mismatch}
  end

  defp evidence_record(directory, archive, public, signature) do
    release = read_json!(Path.join(directory, "release.json"))

    %{
      "schema" => "jido.release-payload",
      "schema_version" => 1,
      "algorithm" => @algorithm,
      "archive" => archive,
      "version" => release["version"] || Identity.version(),
      "license" => release["license"] || "see LICENSE",
      "public_key" => Base.encode64(public),
      "signature" => signature,
      "published" => false,
      "channels" => []
    }
  end

  defp verify_report(directory, record, status) do
    %{
      "status" => Atom.to_string(status),
      "directory" => Path.basename(directory),
      "archive" => record["archive"],
      "version" => record["version"],
      "license" => record["license"],
      "algorithm" => record["algorithm"],
      "published" => false,
      "sealed_at" => record["version"]
    }
    |> then(&Map.put(&1, "summary", Redaction.redact(inspect(&1))))
  end

  defp archive_name(path) when is_binary(path) do
    if File.regular?(path), do: {:ok, Path.basename(path)}, else: {:error, :archive_missing}
  end

  defp find_archive(directory) do
    case Path.wildcard(Path.join(directory, "*.tar.gz")) do
      [archive] -> archive
      _other -> nil
    end
  end

  defp license_path(directory) do
    if File.regular?(Path.join(directory, "LICENSE")), do: "LICENSE", else: "release.json"
  end

  defp sha256_file(path) do
    path
    |> File.stream!(1_048_576, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp checksum_line(body, name_match?) do
    body
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "  ", parts: 2) do
        [sha, name] -> if name_match?.(name), do: sha
        _other -> nil
      end
    end)
  end

  defp decode_key(value) when is_binary(value), do: Base.decode64!(value)

  defp read_json(path) do
    with {:ok, body} <- File.read(path), do: Jason.decode(body)
  end

  defp read_json!(path) do
    case read_json(path) do
      {:ok, value} -> value
      {:error, reason} -> raise "cannot read #{path}: #{inspect(reason)}"
    end
  end

  defp write_json(path, value) do
    File.write(path, Jason.encode!(value, pretty: true) <> "\n")
  end
end
