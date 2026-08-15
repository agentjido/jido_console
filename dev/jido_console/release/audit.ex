defmodule Jido.Console.Release.Audit do
  @moduledoc "Coordinates an explicit local release-readiness audit."

  alias Jido.Console.Release.Readiness

  @doc "Runs selected readiness checks and optionally keeps one local result file."
  @spec run!(keyword()) :: map()
  def run!(opts \\ []) do
    project_root = opts |> Keyword.get(:project_root, File.cwd!()) |> Path.expand()
    checks = Keyword.get(opts, :checks, Readiness.checks())
    validate_checks!(checks)

    source_reader = Keyword.get(opts, :source_reader, &Readiness.source_identity!/1)
    check_runner = Keyword.get(opts, :check_runner, &Readiness.run!/2)
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    source = source_reader.(project_root)
    {output, temporary?} = output_directory(opts)

    if File.exists?(output), do: raise("audit output already exists: #{output}")

    try do
      results =
        Enum.map(checks, fn check ->
          result =
            check_runner.(check,
              project_root: project_root,
              keep_workspaces: Keyword.get(opts, :keep_workspaces, false)
            )

          unless result["status"] == "passed", do: raise("release-readiness check did not pass: #{check}")
          %{"name" => check, "status" => "passed", "result" => result}
        end)

      manifest = %{
        "schema" => "jido.release.readiness-audit",
        "schema_version" => 1,
        "status" => "passed",
        "generated_at" => clock.() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "source" => source,
        "checks" => results,
        "publication" => "not_performed"
      }

      File.mkdir_p!(output)
      write_new!(Path.join(output, "audit.json"), Jason.encode!(manifest, pretty: true) <> "\n")

      %{
        "status" => "passed",
        "manifest" => manifest,
        "output" => if(temporary?, do: nil, else: output),
        "retained" => not temporary?
      }
    after
      if temporary?, do: File.rm_rf!(output)
    end
  end

  defp validate_checks!(checks) when is_list(checks) do
    unknown = checks -- Readiness.checks()
    if unknown != [], do: raise(ArgumentError, "unknown release-readiness checks: #{Enum.join(unknown, ", ")}")
    if checks == [], do: raise(ArgumentError, "select at least one release-readiness check")
    if length(checks) != length(Enum.uniq(checks)), do: raise(ArgumentError, "release-readiness checks must be unique")
  end

  defp validate_checks!(_checks), do: raise(ArgumentError, "release-readiness checks must be a list")

  defp output_directory(opts) do
    case Keyword.get(opts, :output) do
      nil ->
        factory = Keyword.get(opts, :temporary_directory, &temporary_directory/0)
        {factory.(), true}

      path when is_binary(path) ->
        {Path.expand(path), false}

      _other ->
        raise ArgumentError, "audit output must be a path"
    end
  end

  defp temporary_directory do
    id = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "jido-release-audit-#{id}")
  end

  defp write_new!(path, contents) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, device} ->
        try do
          IO.binwrite(device, contents)
        after
          File.close(device)
        end

      {:error, reason} ->
        raise "cannot write audit result #{path}: #{inspect(reason)}"
    end
  end
end
