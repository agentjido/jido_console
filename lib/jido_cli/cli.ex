defmodule Jido.Cli do
  @moduledoc "Command-line entry point for the jido coding harness."

  @usage """
  Usage:
    jido
    jido run --agent FILE (--input FILE|- | --scenario FILE) [options]
    jido eval SUITE [options]

  Options:
    -h, --help       Show this help
    -v, --version    Show the version
        --coding-pack ID        Select a trusted coding pack or `disabled`
        --coding-profile ID     Select the trusted execution profile
        --project-root DIR      Select the trusted coding workspace root
        --model MODEL           Select the interactive provider and model

  Run options:
    -a, --agent FILE           Load one agent YAML or JSON file
    -i, --input FILE|-         Read one prompt from a file or standard input
        --scenario FILE        Run one single-turn or multi-turn scenario
        --model MODEL          Override the model in the agent file
        --runtime-profile ID   Use a trusted runtime capability profile
    -o, --output DIR           Also write run artifacts to a new directory

  Eval options:
    -j, --jobs N               Set the maximum concurrent scenario cells
        --runtime-profile ID   Override the trusted execution profile
    -o, --output DIR           Also write run artifacts to a new directory

  With no command, start jido in an interactive terminal. Provider credentials
  are read from the environment by Jidoka's model provider. Automated commands
  write JSONL records to standard output and diagnostics to standard error.
  """

  @doc "Returns the CLI version."
  @spec version() :: String.t()
  def version, do: Jido.Cli.ReleaseIdentity.version()

  @doc false
  @spec main([String.t()]) :: :ok
  def main(args) do
    case dispatch_fast(args) do
      :continue -> start_and_run(args)
      :ok -> :ok
    end
  end

  defp dispatch_fast([flag]) when flag in ["--help", "-h"], do: print_help()
  defp dispatch_fast([flag]) when flag in ["--version", "-v"], do: print_version()

  defp dispatch_fast([command, flag])
       when command in ["run", "eval"] and flag in ["--help", "-h"],
       do: print_help()

  defp dispatch_fast(_args), do: :continue

  defp start_and_run([command | _rest] = args) when command in ["run", "eval"] do
    with :ok <- start_runtime() do
      handle_run_result(run(args))
    else
      {:error, reason} ->
        fail("could not start: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp start_and_run(args) do
    handle_run_result(run(args, runtime_startup: &start_runtime/0))
  end

  defp start_runtime do
    with :ok <- Jido.Cli.Env.load_provider_credentials(),
         :ok <- start_applications(),
         do: :ok
  end

  defp handle_run_result(:ok), do: :ok
  defp handle_run_result({:error, status}), do: System.halt(status)

  @doc "Runs one CLI invocation and returns its exit status without halting the VM."
  @spec run([String.t()], keyword()) :: :ok | {:error, pos_integer()}
  def run(args, opts \\ []) do
    case args do
      [command, "--help"] when command in ["run", "eval"] ->
        print_help()

      [command, "-h"] when command in ["run", "eval"] ->
        print_help()

      [command | _rest] when command in ["run", "eval"] ->
        run_automation(args, opts)

      _args ->
        run_interactive(args, opts)
    end
  end

  defp run_interactive(args, opts) do
    case OptionParser.parse(args,
           strict: [
             help: :boolean,
             version: :boolean,
             coding_pack: :string,
             coding_profile: :string,
             project_root: :string,
             model: :string
           ],
           aliases: [h: :help, v: :version]
         ) do
      {[help: true], [], []} ->
        print_help()

      {[version: true], [], []} ->
        print_version()

      {options, [], []} ->
        tui = Keyword.get(opts, :tui, Jido.Cli.Tui)
        opts = Keyword.merge(opts, normalize_interactive_options(options))

        case tui.run(opts) do
          :ok -> :ok
          {:error, reason} -> interactive_error(reason)
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

  defp print_help, do: IO.write(@usage)
  defp print_version, do: IO.puts("jido #{version()}")

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
    digest = escript_digest()

    cache =
      Path.join(
        System.tmp_dir!(),
        "jido-#{version()}-otp-#{:erlang.system_info(:otp_release)}-#{digest}"
      )

    with :ok <- ensure_extracted(cache) do
      cache
      |> Path.join("*/ebin")
      |> Path.wildcard()
      |> Enum.each(&:code.add_patha(String.to_charlist(&1)))

      :ok
    end
  end

  defp escript_digest do
    :escript.script_name()
    |> List.to_string()
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
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

  defp normalize_interactive_options(options) do
    Enum.map(options, fn
      {:coding_pack, "disabled"} -> {:coding_pack, :disabled}
      option -> option
    end)
  end

  defp interactive_error(reason) do
    if configuration_error?(reason) do
      IO.puts(:stderr, "jido: #{format_error(reason)}")
      {:error, 64}
    else
      fail(format_error(reason))
    end
  end

  defp configuration_error?({code, _value})
       when code in [:invalid_coding_pack, :invalid_execution_profile, :unknown_runtime_profile],
       do: true

  defp configuration_error?({:unknown_runtime_profile, _id, _reason}), do: true
  defp configuration_error?(:local_coding_root_required), do: true
  defp configuration_error?(:coding_module_name_forbidden), do: true
  defp configuration_error?(:invalid_coding_profile_resolver), do: true
  defp configuration_error?(_reason), do: false

  defp fail(message, prefix \\ "") do
    IO.puts(:stderr, "jido: #{prefix}#{message}")
    {:error, 1}
  end
end
