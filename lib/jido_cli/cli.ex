defmodule Jido.Cli do
  @moduledoc "Command-line entry point for the jido coding harness."

  @version "0.1.0"
  @usage """
  Usage:
    jido

  Options:
    -h, --help       Show this help
    -v, --version    Show the version

  Start jido in an interactive terminal. Provider credentials are read from
  the environment by Jidoka's model provider.
  """

  @doc false
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

  defp format_error(%{__exception__: true} = error), do: Exception.message(error)
  defp format_error(reason) when is_binary(reason), do: reason

  defp format_error(reason) do
    Jidoka.Error.format(reason)
  rescue
    _exception -> inspect(reason)
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
