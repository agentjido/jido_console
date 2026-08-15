defmodule Jido.Console do
  @moduledoc "Command-line entry point for the Jido Console coding harness."

  @usage """
  Usage:
    jido
    jido status
    jido stop [--name NAME]
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
  def version, do: Jido.Console.Release.Identity.version()

  @doc false
  @spec main([String.t()]) :: :ok
  def main(args) do
    case dispatch_fast(args) do
      :continue -> start_probe_or_run(args)
      :ok -> :ok
    end
  end

  defp dispatch_fast([flag]) when flag in ["--help", "-h"], do: print_help()
  defp dispatch_fast([flag]) when flag in ["--version", "-v"], do: print_version()

  defp dispatch_fast([command, flag])
       when command in ["run", "eval", "status", "stop"] and flag in ["--help", "-h"],
       do: print_help()

  defp dispatch_fast(_args), do: :continue

  defp start_probe_or_run(args) do
    if release_probe?() do
      System.halt(Jido.Console.Release.Entry.run(args))
    else
      start_and_run(args)
    end
  end

  defp release_probe? do
    System.get_env("JIDO_RELEASE_NATIVE_PROBE") != nil or
      System.get_env("JIDO_RELEASE_TUI_PROBE") != nil
  end

  defp start_and_run([command | _rest] = args) when command in ["run", "eval"] do
    case start_runtime() do
      :ok ->
        handle_run_result(run(args))

      {:error, reason} ->
        fail("could not start: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp start_and_run(args) do
    handle_run_result(run(args, runtime_startup: &start_runtime/0))
  end

  defp start_runtime do
    with :ok <- Jido.Console.Env.load_provider_credentials(),
         do: Jido.Console.Bootstrap.start_applications()
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

      ["status" | rest] ->
        run_process_status(rest, opts)

      ["stop" | rest] ->
        run_process_stop(rest, opts)

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
      {options, [], []} ->
        case Jido.Console.InteractiveOptions.parse(options) do
          {:ok, %{help: true}} -> print_help()
          {:ok, %{version: true}} -> print_version()
          {:ok, options} -> start_tui(options, opts)
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

  defp run_process_status(args, opts) do
    case OptionParser.parse(args, strict: [help: :boolean], aliases: [h: :help]) do
      {options, [], []} ->
        if Keyword.get(options, :help) do
          print_help()
        else
          with {:ok, records} <- Jido.Console.Process.list(opts) do
            IO.write(Jido.Console.Process.format_status(records))
          end
          |> normalize_process_result()
        end

      _other ->
        usage_error()
    end
  end

  defp run_process_stop(args, opts) do
    case OptionParser.parse(args, strict: [help: :boolean, name: :string], aliases: [h: :help]) do
      {options, [], []} ->
        if Keyword.get(options, :help) do
          print_help()
        else
          stop_processes(Keyword.get(options, :name), opts)
        end

      _other ->
        usage_error()
    end
  end

  defp stop_processes(nil, opts) do
    with {:ok, records} <- Jido.Console.Process.stop_all(opts) do
      if records == [] do
        IO.write("jido: no owned background processes\n")
      else
        Enum.each(records, fn record -> IO.write(Jido.Console.Process.format_stop(record)) end)
      end

      :ok
    end
    |> normalize_process_result()
  end

  defp stop_processes(name, opts) do
    with {:ok, record} <- Jido.Console.Process.stop(name, opts) do
      IO.write(Jido.Console.Process.format_stop(record))
    end
    |> normalize_process_result()
  end

  defp normalize_process_result(:ok), do: :ok

  defp normalize_process_result({:error, reason}) do
    IO.puts(:stderr, "jido: #{format_error(reason)}")
    {:error, 1}
  end

  defp run_automation(args, opts) do
    automation = Keyword.get(opts, :automation, Jido.Console.Automation)

    opts =
      Keyword.put_new(
        opts,
        :cancellation_source,
        Jido.Console.Automation.Interrupt.Signal
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

  defp format_error(reason) do
    reason
    |> Jido.Console.Error.normalize()
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

  defp start_tui(options, opts) do
    tui = Keyword.get(opts, :tui, Jido.Console.Tui)
    interactive = options |> Map.to_list() |> normalize_interactive_options()

    case tui.run(Keyword.merge(opts, interactive)) do
      :ok -> :ok
      {:error, reason} -> interactive_error(reason)
    end
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
  defp configuration_error?({:invalid_interactive_options, _errors}), do: true
  defp configuration_error?(_reason), do: false

  defp fail(message, prefix \\ "") do
    IO.puts(:stderr, "jido: #{prefix}#{message}")
    {:error, 1}
  end
end
