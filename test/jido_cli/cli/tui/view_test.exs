defmodule Jido.Cli.Tui.ViewTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.Tui.State
  alias Jido.Cli.Tui.View

  test "renders a useful warning when the terminal is too small" do
    frame = State.new(:session, {10, 4}) |> View.render()
    assert Enum.join(frame.rows, "\n") =~ "Terminal i"
    assert frame.cursor == nil
  end

  test "renders streaming content as a temporary assistant message" do
    state = %{
      State.new(:session, {40, 10})
      | messages: [%{role: :user, content: "hello"}],
        streaming: "working",
        status: :running
    }

    text = state |> View.render() |> Map.fetch!(:rows) |> Enum.join("\n")
    assert text =~ "User"
    assert text =~ "Assistant"
    assert text =~ "working"
    assert text =~ "running · Ctrl-C cancels"
  end

  test "renders each terminal status" do
    cases = [
      {:cancelling, nil, "cancelling"},
      {:interrupted, nil, "paused"},
      {:interrupted, "review needed", "review needed"},
      {:error, "failed", "error · failed"},
      {:custom, nil, "custom"}
    ]

    for {status, error, expected} <- cases do
      state = %{State.new(:session, {40, 8}) | status: status, error: error}
      text = state |> View.render() |> Map.fetch!(:rows) |> Enum.join("\n")
      assert text =~ expected
    end
  end
end
