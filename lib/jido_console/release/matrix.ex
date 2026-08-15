defmodule Jido.Console.Release.Matrix do
  @moduledoc """
  Verifies the v0.1 macOS ARM64 channel matrix against one signed payload.
  """

  alias Jido.Console.Providers.Redaction
  alias Jido.Console.Release.Channel

  @supported_cells [
    %{platform: "darwin", arch: "arm64", channel: :archive},
    %{platform: "darwin", arch: "arm64", channel: :homebrew},
    %{platform: "darwin", arch: "arm64", channel: :npm}
  ]

  @doc "Returns the required v0.1 support cells."
  @spec cells() :: [map()]
  def cells, do: @supported_cells

  @doc "Runs install, first run, update, and removal for every required cell."
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
    prefix = Path.join(root, "#{cell.channel}")

    case run_lifecycle(cell.channel, payload_dir, prefix, opts) do
      {:ok, install, stages} ->
        %{
          "platform" => cell.platform,
          "arch" => cell.arch,
          "channel" => Atom.to_string(cell.channel),
          "status" => "pass",
          "version" => install.version,
          "license" => install.license,
          "payload_sha256" => install.payload_sha256,
          "stages" => stages
        }

      {:error, {stage, reason}} ->
        %{
          "platform" => cell.platform,
          "arch" => cell.arch,
          "channel" => Atom.to_string(cell.channel),
          "status" => "fail",
          "stage" => Atom.to_string(stage),
          "reason" => inspect(reason)
        }
    end
  end

  defp run_lifecycle(channel, payload_dir, prefix, opts) do
    with {:ok, install} <- stage(:install, fn -> Channel.install(channel, payload_dir, prefix, opts) end),
         {:ok, first} <- stage(:first_run, fn -> Channel.first_run(install) end),
         {:ok, _updated} <- stage(:update, fn -> Channel.update(install, payload_dir, opts) end),
         {:ok, removed} <- stage(:remove, fn -> Channel.remove(install) end) do
      {:ok, install, [first, removed]}
    end
  end

  defp stage(name, fun) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {name, reason}}
    end
  end

  defp compare(results) do
    passed = Enum.filter(results, &(&1["status"] == "pass"))
    shas = passed |> Enum.map(& &1["payload_sha256"]) |> Enum.uniq()
    versions = passed |> Enum.map(& &1["version"]) |> Enum.uniq()
    licenses = passed |> Enum.map(& &1["license"]) |> Enum.uniq()

    cond do
      passed == [] -> %{"status" => "fail", "reason" => "no passing cells"}
      length(shas) != 1 -> %{"status" => "fail", "reason" => "payload checksum mismatch"}
      length(versions) != 1 -> %{"status" => "fail", "reason" => "version mismatch"}
      length(licenses) != 1 -> %{"status" => "fail", "reason" => "license mismatch"}
      true -> %{"status" => "pass", "payload_sha256" => hd(shas), "version" => hd(versions)}
    end
  end

  defp report(results, comparison) do
    %{
      "schema" => "jido.channel-matrix",
      "schema_version" => 1,
      "supported_cells" => results,
      "untested" => ["linux", "windows", "darwin-x64"],
      "comparison" => comparison,
      "decision" =>
        if(comparison["status"] == "pass" and Enum.all?(results, &(&1["status"] == "pass")), do: "pass", else: "fail"),
      "summary" => Redaction.redact("matrix #{length(results)} cells")
    }
  end
end
