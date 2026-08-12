defmodule Jido.Cli do
  @moduledoc "Command-line entry point for the jido coding harness."

  @version "0.1.0"
  @usage """
  Usage:
    jido
    jido run --agent FILE (--input FILE|- | --scenario FILE) [options]
    jido eval SUITE [options]

  Options:
    -h, --help       Show this help
    -v, --version    Show the version

  Run options:
    -a, --agent FILE           Load one agent YAML or JSON file
    -i, --input FILE|-         Read one prompt from a file or standard input
        --scenario FILE        Run one single-turn or multi-turn scenario
        --model MODEL          Override the model in the agent file
        --runtime-profile ID   Use a trusted runtime capability profile
    -o, --output DIR           Also write run artifacts to a new directory

  Eval options:
    -j, --jobs N               Set the maximum concurrent scenario cells
    -o, --output DIR           Also write run artifacts to a new directory

  With no command, start jido in an interactive terminal. Provider credentials
  are read from the environment by Jidoka's model provider. Automated commands
  write JSONL records to standard output and diagnostics to standard error.
  """

  @doc "Returns the CLI version."
  @spec version() :: String.t()
  def version, do: @version

  @doc false
  @spec main([String.t()]) :: :ok
  def main(args) do
    with :ok <- start_applications() do
      case run(args) do
        :ok -> :ok
        {:error, status} -> System.halt(status)
      end
    else
      {:error, reason} ->
        fail("could not start: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc "Runs one CLI invocation and returns its exit status without halting the VM."
  @spec run([String.t()], keyword()) :: :ok | {:error, pos_integer()}
  def run(args, opts \\ []) do
    case args do
      [command, "--help"] when command in ["run", "eval"] ->
        IO.write(@usage)
        :ok

      [command, "-h"] when command in ["run", "eval"] ->
        IO.write(@usage)
        :ok

      [command | _rest] when command in ["run", "eval"] ->
        run_automation(args, opts)

      _args ->
        run_interactive(args, opts)
    end
  end

  defp run_interactive(args, opts) do
    case OptionParser.parse(args,
           strict: [help: :boolean, version: :boolean],
           aliases: [h: :help, v: :version]
         ) do
      {[help: true], [], []} ->
        IO.write(@usage)
        :ok

      {[version: true], [], []} ->
        IO.puts("jido #{@version}")
        :ok

      {[], [], []} ->
        tui = Keyword.get(opts, :tui, Jido.Cli.Tui)

        case tui.run(opts) do
          :ok -> :ok
          {:error, reason} -> fail(format_error(reason))
        end

      {_options, _arguments, invalid} when invalid != [] ->
        invalid
        |> Enum.map_join(", ", fn {option, _value} -> option end)
        |> fail("unknown option: ")

      _other ->
        usage_error()
    end
  end

  defp run_automation(args, opts) do
    automation = Keyword.get(opts, :automation, Jido.Cli.Automation)

    opts =
      Keyword.put_new(
        opts,
        :cancellation_source,
        Jido.Cli.Automation.Interrupt.Signal
      )

    case automation.execute(args, opts) do
      {:ok, %{status: :passed}} ->
        :ok

      {:ok, %{status: :failed} = summary} ->
        IO.puts(:stderr, "jido: automated run failed: #{format_summary(summary)}")
        {:error, 1}

      {:ok, %{status: :cancelled} = summary} ->
        IO.puts(:stderr, "jido: automated run cancelled: #{format_summary(summary)}")
        {:error, 1}

      {:error, kind, reason} when kind in [:usage, :configuration] ->
        IO.puts(:stderr, "jido: #{format_error(reason)}")
        {:error, 64}

      {:error, :execution, reason} ->
        fail(format_error(reason))

      other ->
        fail("invalid automation result: #{inspect(other)}")
    end
  end

  # Escript archives can contain priv files, but libraries using File.read/1 cannot
  # access them in place. Extract once to a versioned cache and put those normal
  # application directories ahead of the archive before starting dependencies.
  defp start_applications do
    with :ok <- make_priv_files_accessible(),
         {:ok, _applications} <- Application.ensure_all_started(:jido_cli) do
      :ok
    end
  end

  defp make_priv_files_accessible do
    case :code.priv_dir(:time_zone_info) do
      path when is_list(path) ->
        if path |> List.to_string() |> File.dir?() do
          :ok
        else
          extract_escript()
        end

      _other ->
        extract_escript()
    end
  end

  defp extract_escript do
    cache =
      Path.join(
        System.tmp_dir!(),
        "jido-#{@version}-otp-#{:erlang.system_info(:otp_release)}"
      )

    with :ok <- ensure_extracted(cache) do
      cache
      |> Path.join("*/ebin")
      |> Path.wildcard()
      |> Enum.each(&:code.add_patha(String.to_charlist(&1)))

      :ok
    end
  end

  defp ensure_extracted(cache) do
    marker = Path.join(cache, ".complete")

    if File.regular?(marker) do
      :ok
    else
      with {:ok, sections} <- :escript.extract(:escript.script_name(), []),
           {:ok, archive} <- Keyword.fetch(sections, :archive),
           :ok <- File.mkdir_p(cache),
           {:ok, _files} <- :zip.extract(archive, cwd: String.to_charlist(cache)),
           :ok <- File.write(marker, "") do
        :ok
      end
    end
  end

  defp format_error(reason) do
    reason
    |> Jido.Cli.Error.normalize()
    |> Exception.message()
  rescue
    _exception -> inspect(reason)
  end

  defp format_summary(summary) do
    counts = Map.get(summary, :counts, %{})

    "#{Map.get(counts, :failed, 0)} failed, " <>
      "#{Map.get(counts, :errors, 0)} errors, " <>
      "#{Map.get(counts, :cancelled, 0)} cancelled"
  end

  defp usage_error do
    IO.write(:stderr, @usage)
    {:error, 64}
  end

  defp fail(message, prefix \\ "") do
    IO.puts(:stderr, "jido: #{prefix}#{message}")
    {:error, 1}
  end
end
