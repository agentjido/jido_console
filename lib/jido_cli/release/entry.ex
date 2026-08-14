defmodule Jido.Cli.Release.Entry do
  @moduledoc false

  @doc false
  @spec main() :: no_return()
  def main do
    args = Enum.map(:init.get_plain_arguments(), &List.to_string/1)
    System.halt(run(args))
  end

  @doc false
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(args, opts \\ []) when is_list(args) and is_list(opts) do
    native_probe = option_env(opts, :native_probe, "JIDO_RELEASE_NATIVE_PROBE")
    tui_probe = option_env(opts, :tui_probe, "JIDO_RELEASE_TUI_PROBE")

    case {native_probe, tui_probe} do
      {"1", nil} -> run_native_probe(opts)
      {nil, tui_mode} -> dispatch(args, tui_mode, opts)
      _other -> error(opts, "jido: invalid release probe configuration", 64)
    end
  end

  defp dispatch(args, tui_mode, opts) do
    case tui_mode do
      nil ->
        Keyword.get(opts, :cli_main, &Jido.Cli.main/1).(args)
        0

      mode when mode in ["success", "failure", "workflow"] ->
        run_tui_probe(args, mode, opts)

      _other ->
        error(opts, "jido: invalid release TUI probe mode", 64)
    end
  end

  defp run_native_probe(opts) do
    ensure_started = Keyword.get(opts, :ensure_all_started, &Application.ensure_all_started/1)
    extract = Keyword.get(opts, :extract_from_bytes, &ExtractousEx.extract_from_bytes/1)

    with {:ok, _applications} <- ensure_started.(:jido_cli),
         {:ok, %{content: content}} <- extract.("Jido native release probe."),
         true <- String.contains?(content, "Jido native release probe") do
      output(opts, "jido release native probe passed")
      0
    else
      reason -> error(opts, "jido: release native probe failed: #{inspect(reason)}", 1)
    end
  end

  defp run_tui_probe(args, mode, opts) do
    delay_ms = probe_delay_ms(opts)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)

    startup = fn ->
      sleep.(delay_ms)
      if mode == "failure", do: {:error, :release_probe_failure}, else: :ok
    end

    cli_run = Keyword.get(opts, :cli_run, &Jido.Cli.run/2)

    tui_opts = [
      runtime: Jido.Cli.Release.ProbeRuntime,
      runtime_startup: startup,
      coding_pack: :disabled,
      session_opts: probe_session_opts(mode, opts)
    ]

    case cli_run.(args, tui_opts) do
      :ok -> 0
      {:error, status} -> status
    end
  end

  defp probe_session_opts("workflow", opts) do
    [
      probe_mode: :workflow,
      probe_workspace: probe_option(opts, :probe_workspace, "JIDO_RELEASE_TUI_PROBE_WORKSPACE"),
      probe_expected: probe_option(opts, :probe_expected, "JIDO_RELEASE_TUI_PROBE_EXPECTED"),
      probe_log: probe_option(opts, :probe_log, "JIDO_RELEASE_TUI_PROBE_LOG"),
      probe_verifier: probe_verifier(opts)
    ]
  end

  defp probe_session_opts(_mode, opts) do
    [
      probe_mode: :success,
      probe_log: probe_option(opts, :probe_log, "JIDO_RELEASE_TUI_PROBE_LOG")
    ]
  end

  defp probe_option(opts, key, environment) do
    Keyword.get_lazy(opts, key, fn -> System.get_env(environment) end)
  end

  defp probe_delay_ms(opts) do
    value =
      Keyword.get_lazy(opts, :tui_probe_delay_ms, fn -> System.get_env("JIDO_RELEASE_TUI_PROBE_DELAY_MS", "400") end)

    case Integer.parse(to_string(value)) do
      {delay, ""} when delay >= 0 and delay <= 10_000 -> delay
      _other -> 400
    end
  end

  defp probe_verifier(opts) do
    case probe_option(opts, :probe_verifier, "JIDO_RELEASE_TUI_PROBE_VERIFIER") do
      nil -> :mix_test
      "mix_test" -> :mix_test
      "private_runtime" -> :private_runtime
      other -> other
    end
  end

  defp option_env(opts, key, environment) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> System.get_env(environment)
    end
  end

  defp output(opts, message) do
    Keyword.get(opts, :output, &IO.puts/1).(message)
    :ok
  end

  defp error(opts, message, status) do
    Keyword.get(opts, :error_output, fn value -> IO.puts(:stderr, value) end).(message)
    status
  end
end
