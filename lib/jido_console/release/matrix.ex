defmodule Jido.Console.Release.Matrix do
  @moduledoc """
  Validates and compares the macOS ARM64 channel-owner results.
  """

  alias Jido.Console.Providers.Redaction
  alias Jido.Console.Release.{Channel, Homebrew, Npm}

  @supported_cells [
    %{platform: "darwin", arch: "arm64", channel: :archive, owner: Channel},
    %{platform: "darwin", arch: "arm64", channel: :homebrew, owner: Homebrew},
    %{platform: "darwin", arch: "arm64", channel: :npm, owner: Npm}
  ]

  @doc "Returns the required support cells without internal owner modules."
  @spec cells() :: [map()]
  def cells, do: Enum.map(@supported_cells, &Map.drop(&1, [:owner]))

  @doc "Collects, validates, and compares every required channel result."
  @spec verify(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(payload_dir, opts \\ []) do
    root =
      Keyword.get_lazy(opts, :root, fn ->
        Path.join(System.tmp_dir!(), "jido-matrix-#{System.unique_integer([:positive])}")
      end)

    File.mkdir_p!(root)

    results = Enum.map(@supported_cells, &verify_cell(&1, payload_dir, root, opts))
    comparison = compare(results)
    report = report(results, comparison)

    if Enum.all?(results, &(&1["status"] == "pass")) and comparison["status"] == "pass" do
      {:ok, report}
    else
      {:error, {:matrix_failed, report}}
    end
  end

  defp verify_cell(cell, payload_dir, root, opts) do
    prefix = Path.join(root, Atom.to_string(cell.channel))
    result = cell.owner.lifecycle(payload_dir, prefix, opts)

    case Channel.validate_result(result, cell.channel) do
      :ok ->
        Map.merge(result, %{"platform" => cell.platform, "arch" => cell.arch})

      {:error, reason} ->
        result
        |> Map.put("status", "fail")
        |> Map.put("validation_error", inspect(reason))
        |> Map.merge(%{"platform" => cell.platform, "arch" => cell.arch})
    end
  end

  @doc false
  @spec compare([Channel.result()]) :: map()
  def compare(results) do
    identities = results |> Enum.map(& &1["payload_identity"]) |> Enum.uniq()

    case identities do
      [identity] ->
        %{
          "status" => "pass",
          "checksum" => identity["checksum"],
          "provenance" => identity["provenance"],
          "version" => identity["version"],
          "license" => identity["license"]
        }

      _other ->
        %{"status" => "fail", "reason" => identity_mismatch(identities)}
    end
  end

  defp identity_mismatch(identities) do
    fields = ~w(checksum provenance version license)

    fields
    |> Enum.filter(fn field -> identities |> Enum.map(& &1[field]) |> Enum.uniq() |> length() > 1 end)
    |> Enum.join(", ")
    |> case do
      "" -> "payload identity unavailable"
      changed -> "payload identity mismatch: #{changed}"
    end
  end

  defp report(results, comparison) do
    decision =
      if comparison["status"] == "pass" and Enum.all?(results, &(&1["status"] == "pass")),
        do: "pass",
        else: "fail"

    %{
      "schema" => "jido.channel-matrix",
      "schema_version" => 1,
      "supported_cells" => results,
      "untested" => ["linux", "windows", "darwin-x64"],
      "comparison" => comparison,
      "decision" => decision,
      "summary" => Redaction.redact("matrix #{length(results)} cells")
    }
  end
end
