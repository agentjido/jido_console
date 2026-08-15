defmodule Jido.Console.Session.ResultTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Result

  test "content and view stay separate and renderer-neutral" do
    {:ok, result} = Result.new(content: "hello", view: %{status: "done"})
    assert Result.to_protocol(result)["content"] == "hello"
    assert Result.to_protocol(result)["view"]["status"] == "done"
    assert {:error, :renderer_value_forbidden} = Result.new(view: %{ansi: "red"})
  end
end
