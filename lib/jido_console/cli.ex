defmodule Jido.Console.CLI do
  @moduledoc "Command-line implementation for the Jido Console coding harness."

  @usage """
  Usage:
    jido
    jido status
    jido stop [--name NAME]
    jido auth status [--provider NAME] [--env-file FILE]
    jido auth doctor [--provider NAME] [--env-file FILE]
    jido doctor [--provider NAME] [--env-file FILE]
    jido models list
    jido models show PROVIDER MODEL

  Options:
    -h, --help       Show this help
    -v, --version    Show the version
        --coding-pack ID        Select a trusted coding pack or `disabled`
        --coding-profile ID     Select the trusted execution profile
        --project-root DIR      Select the trusted coding workspace root
        --model MODEL           Select the interactive provider and model

  With no command, start jido in an interactive terminal. Provider credentials
  are read from the environment by Jidoka's model provider.
  """

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
       when command in ["status", "stop", "doctor", "auth", "models"] and
              flag in ["--help", "-h"],
       do: print_help()

  defp dispatch_fast(["auth", command, flag])
       when command in ["status", "doctor"] and flag in ["--help", "-h"],
       do: print_help()

  defp dispatch_fast(["models", command, flag])
       when command in ["list", "show"] and flag in ["--help", "-h"],
       do: print_help()

  defp dispatch_fast(_args), do: :continue

  defp start_and_run([command | _rest] = args)
       when command in ["status", "stop", "auth", "doctor", "models"] do
    case start_runtime() do
      :ok ->
        handle_run_result(run(args))

      {:error, reason} ->
        fail("could not start: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp start_and_run(args) do
    handle_run_result(run(args, application_startup: &start_runtime/0))
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
      ["status" | rest] ->
        run_process_status(rest, opts)

      ["stop" | rest] ->
        run_process_stop(rest, opts)

      ["auth" | rest] ->
        run_auth(rest, opts)

      ["doctor" | rest] ->
        run_doctor(rest, opts)

      ["models" | rest] ->
        run_models(rest, opts)

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
    {:error, if(configuration_reason?(reason), do: 64, else: 1)}
  end

  defp configuration_reason?(reason)
       when reason in [
              :credential_argument_rejected,
              :invalid_auth_options,
              :invalid_provider,
              :invalid_model_identity,
              :invalid_model_options
            ],
       do: true

  defp configuration_reason?({:unknown_provider, _provider}), do: true
  defp configuration_reason?({:unsafe_permissions, _path, _mode}), do: true
  defp configuration_reason?({:dotenv_permissions_too_open, _path}), do: true
  defp configuration_reason?(_reason), do: false

  defp run_auth(["status" | rest], opts), do: run_auth_status(rest, opts)
  defp run_auth(["doctor" | rest], opts), do: run_doctor(rest, opts)
  defp run_auth(["--help"], _opts), do: print_help()
  defp run_auth(["-h"], _opts), do: print_help()
  defp run_auth(_args, _opts), do: usage_error()

  defp run_auth_status(args, opts) do
    with :ok <- Jido.Console.Auth.reject_credential_args(args),
         {:ok, options} <- parse_auth_options(args) do
      if Keyword.get(options, :help) do
        print_help()
      else
        with {:ok, rows} <- Jido.Console.Auth.status(Keyword.merge(opts, options)) do
          IO.write(Jido.Console.Auth.format_status(rows))
        end
      end
    end
    |> normalize_process_result()
  end

  defp run_doctor(args, opts) do
    with :ok <- Jido.Console.Auth.reject_credential_args(args),
         {:ok, options} <- parse_auth_options(args) do
      if Keyword.get(options, :help) do
        print_help()
      else
        with {:ok, report} <- Jido.Console.Auth.doctor(Keyword.merge(opts, options)) do
          IO.write(Jido.Console.Auth.format_doctor(report))
        end
      end
    end
    |> normalize_process_result()
  end

  defp run_models(["list" | rest], opts), do: run_models_list(rest, opts)
  defp run_models(["show" | rest], opts), do: run_models_show(rest, opts)
  defp run_models(["--help"], _opts), do: print_help()
  defp run_models(["-h"], _opts), do: print_help()
  defp run_models(_args, _opts), do: usage_error()

  defp run_models_list(args, opts) do
    with :ok <- Jido.Console.Auth.reject_credential_args(args),
         {:ok, options} <- parse_models_options(args, []) do
      if Keyword.get(options, :help), do: print_help(), else: write_models(Jido.Console.Models.Commands.list(opts))
    end
    |> normalize_models_result()
  end

  defp run_models_show(args, opts) do
    with :ok <- Jido.Console.Auth.reject_credential_args(args),
         {:ok, identity, options} <- parse_models_target(args) do
      if Keyword.get(options, :help) do
        print_help()
      else
        write_models(apply_models_show(identity, opts))
      end
    end
    |> normalize_models_result()
  end

  defp apply_models_show({provider, model}, opts), do: Jido.Console.Models.Commands.show(provider, model, opts)
  defp apply_models_show(identity, opts), do: Jido.Console.Models.Commands.show(identity, nil, opts)

  defp write_models({:ok, output}) do
    IO.write(output)
    :ok
  end

  defp write_models(other), do: other

  defp parse_models_target(args) do
    case OptionParser.parse(args, strict: [help: :boolean], aliases: [h: :help]) do
      {options, [], []} ->
        if Keyword.get(options, :help), do: {:ok, nil, [help: true]}, else: {:error, :invalid_model_identity}

      {options, [identity], []} ->
        {:ok, identity, Keyword.take(options, [:help])}

      {options, [provider, model], []} ->
        {:ok, {provider, model}, Keyword.take(options, [:help])}

      {_options, _args, _invalid} ->
        {:error, :invalid_model_options}
    end
  end

  defp parse_models_options(args, extra) do
    case OptionParser.parse(args,
           strict: [help: :boolean] ++ Enum.map(extra, &{&1, :boolean}),
           aliases: [h: :help]
         ) do
      {options, [], []} -> {:ok, options}
      {_options, _args, _invalid} -> {:error, :invalid_model_options}
    end
  end

  defp normalize_models_result(:ok), do: :ok
  defp normalize_models_result({:error, {:unknown_model, _identity} = reason}), do: config_error(reason)
  defp normalize_models_result({:error, :invalid_model_identity}), do: usage_error()
  defp normalize_models_result({:error, :invalid_model_options}), do: usage_error()
  defp normalize_models_result({:error, reason}), do: normalize_process_result({:error, reason})

  defp config_error(reason) do
    IO.puts(:stderr, "jido: #{format_error(reason)}")
    {:error, 64}
  end

  defp parse_auth_options(args) do
    case OptionParser.parse(args,
           strict: [help: :boolean, provider: :string, env_file: :string],
           aliases: [h: :help]
         ) do
      {options, [], []} ->
        if Keyword.get(options, :help) do
          {:ok, [help: true]}
        else
          {:ok, Keyword.take(options, [:provider, :env_file])}
        end

      {_options, _args, _invalid} ->
        {:error, :invalid_auth_options}
    end
  end

  defp print_help, do: IO.write(@usage)
  defp print_version, do: IO.puts("jido #{Jido.Console.Version.current()}")

  defp format_error(reason) do
    Jido.Console.Error.message(reason)
  rescue
    _exception -> inspect(reason)
  end

  defp usage_error do
    IO.write(:stderr, @usage)
    {:error, 64}
  end

  defp start_tui(options, opts) do
    tui = Keyword.get(opts, :tui, Jido.Console.Tui)
    interactive = options |> Map.to_list() |> normalize_interactive_options()
    opts = Keyword.put_new(opts, :application_startup, &start_runtime/0)

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
