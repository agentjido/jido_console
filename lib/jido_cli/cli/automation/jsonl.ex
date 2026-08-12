defmodule Jido.Cli.Automation.JSONL do
  @moduledoc "Writes case result records to standard output and optional run files."

  defstruct [:root, stdout: :stdio]

  @type t :: %__MODULE__{root: String.t() | nil, stdout: IO.device()}

  @doc "Opens an output sink and writes the run manifest when a directory is set."
  @spec open(map(), String.t() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  def open(manifest, output_dir, opts \\ []) do
    stdout = Keyword.get(opts, :output_device, :stdio)

    case output_dir do
      nil ->
        {:ok, %__MODULE__{stdout: stdout}}

      output_dir when is_binary(output_dir) and output_dir != "" ->
        root = Path.expand(output_dir)

        with :ok <- prepare_directory(root),
             :ok <- File.mkdir_p(Path.join(root, "by-agent")),
             :ok <- write_json(Path.join(root, "manifest.json"), manifest) do
          {:ok, %__MODULE__{root: root, stdout: stdout}}
        end

      output_dir ->
        {:error, {:invalid_output_directory, output_dir}}
    end
  end

  @doc "Writes one complete result as one physical JSON line."
  @spec emit(t(), map()) :: :ok | {:error, term()}
  def emit(%__MODULE__{} = sink, result) do
    with {:ok, json} <- Jason.encode(result),
         line = json <> "\n",
         :ok <- write_device(sink.stdout, line),
         :ok <- maybe_append(sink.root, "results.jsonl", line),
         :ok <- maybe_append_agent(sink.root, result, line) do
      :ok
    end
  end

  @doc "Writes the final summary when file output is enabled."
  @spec finish(t(), map()) :: :ok | {:error, term()}
  def finish(%__MODULE__{root: nil}, _summary), do: :ok

  def finish(%__MODULE__{root: root}, summary) do
    write_json(Path.join(root, "summary.json"), summary)
  end

  defp prepare_directory(root) do
    case File.ls(root) do
      {:ok, []} -> :ok
      {:ok, entries} -> {:error, {:output_directory_not_empty, root, entries}}
      {:error, :enoent} -> File.mkdir_p(root)
      {:error, reason} -> {:error, {:output_directory_unavailable, root, reason}}
    end
  end

  defp write_json(path, value) do
    with {:ok, json} <- Jason.encode(value, pretty: true),
         :ok <- File.write(path, json <> "\n"),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp write_device(device, line) do
    case IO.write(device, line) do
      :ok -> :ok
      {:error, reason} -> {:error, {:jsonl_write_failed, reason}}
    end
  end

  defp maybe_append(nil, _relative_path, _line), do: :ok

  defp maybe_append(root, relative_path, line) do
    path = Path.join(root, relative_path)

    with :ok <- File.write(path, line, [:append]),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp maybe_append_agent(nil, _result, _line), do: :ok

  defp maybe_append_agent(root, result, line) do
    agent_key = get_in(result, [:dimensions, :agent_key])
    maybe_append(root, Path.join("by-agent", artifact_key(agent_key) <> ".jsonl"), line)
  end

  defp artifact_key(key) when is_binary(key) do
    safe =
      key
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._-]+/, "-")
      |> String.replace(~r/^[.-]+|[.-]+$/, "")

    if safe != "" and safe == key do
      safe
    else
      digest = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> String.slice(0, 12)
      "#{if(safe == "", do: "agent", else: safe)}-#{digest}"
    end
  end
end
