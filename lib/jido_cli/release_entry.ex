defmodule Jido.Cli.ReleaseEntry do
  @moduledoc false

  @doc false
  @spec main() :: no_return()
  def main do
    args = Enum.map(:init.get_plain_arguments(), &List.to_string/1)

    status =
      case {System.get_env("JIDO_RELEASE_NATIVE_PROBE"), System.get_env("JIDO_RELEASE_TUI_PROBE")} do
        {"1", nil} ->
          run_native_probe()

        {nil, tui_mode} ->
          dispatch(args, tui_mode)

        _other ->
          IO.puts(:stderr, "jido: invalid release probe configuration")
          64
      end

    System.halt(status)
  end

  defp dispatch(args, tui_mode) do
    case tui_mode do
      nil ->
        Jido.Cli.main(args)
        0

      mode when mode in ["success", "failure"] ->
        run_tui_probe(args, mode)

      _other ->
        IO.puts(:stderr, "jido: invalid release TUI probe mode")
        64
    end
  end

  defp run_native_probe do
    with {:ok, _applications} <- Application.ensure_all_started(:jido_cli),
         {:ok, %{content: content}} <- ExtractousEx.extract_from_bytes("Jido native release probe."),
         true <- String.contains?(content, "Jido native release probe") do
      IO.puts("jido release native probe passed")
      0
    else
      reason ->
        IO.puts(:stderr, "jido: release native probe failed: #{inspect(reason)}")
        1
    end
  end

  defp run_tui_probe(args, mode) do
    delay_ms = probe_delay_ms()

    startup = fn ->
      Process.sleep(delay_ms)
      if mode == "failure", do: {:error, :release_probe_failure}, else: :ok
    end

    result =
      Jido.Cli.run(args,
        runtime: Jido.Cli.Release.ProbeRuntime,
        runtime_startup: startup,
        coding_pack: :disabled
      )

    case result do
      :ok -> 0
      {:error, status} -> status
    end
  end

  defp probe_delay_ms do
    case Integer.parse(System.get_env("JIDO_RELEASE_TUI_PROBE_DELAY_MS", "400")) do
      {value, ""} when value >= 0 and value <= 10_000 -> value
      _other -> 400
    end
  end
end
