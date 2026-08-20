defmodule Jido.Console.Tui do
  @moduledoc "Full-screen TermUI client for one Console thread."

  alias Jido.Console.Tui.{App, Selection}
  alias TermUI.Runtime

  @frame_interval_ms 33

  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    opts = initial_selection(opts)
    result_ref = make_ref()
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      opts
      |> runtime_options(result_ref)
      |> Runtime.run()
      |> runtime_result(result_ref)
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp runtime_options(opts, result_ref) do
    backend =
      case Keyword.get(opts, :term_ui_backend) do
        nil -> :auto
        module -> {module, Keyword.get(opts, :term_ui_backend_opts, [])}
      end

    [
      root: App,
      tui_opts: opts,
      result_owner: self(),
      result_ref: result_ref,
      backend: backend,
      render_interval: Keyword.get(opts, :render_interval_ms, @frame_interval_ms),
      use_input_handler: Keyword.get(opts, :use_input_handler, false)
    ]
  end

  defp runtime_result({:error, {failure, reason}}, _result_ref)
       when failure in [:backend_draw_failed, :backend_flush_failed],
       do: {:error, reason}

  defp runtime_result({:error, {:shutdown, {failure, reason}}}, _result_ref)
       when failure in [:backend_draw_failed, :backend_flush_failed],
       do: {:error, reason}

  defp runtime_result({:error, reason}, _result_ref), do: {:error, reason}

  defp runtime_result(:ok, result_ref) do
    receive do
      {:jido_tui_result, ^result_ref, result} -> result
    after
      0 -> :ok
    end
  end

  defp initial_selection(opts) do
    selection = Selection.init(opts)

    opts
    |> Keyword.put(:catalog_entries, selection.catalog_entries)
    |> Keyword.put(:model, selection.model)
    |> Keyword.put(:coding_profile, selection.profile_id)
  end
end
