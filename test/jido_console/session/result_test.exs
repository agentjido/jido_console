defmodule Jido.Console.Session.ResultTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Result

  test "content and view stay separate and renderer-neutral" do
    {:ok, result} = Result.new(content: "hello", view: %{status: "done"})
    assert Result.to_protocol(result)["content"] == "hello"
    assert Result.to_protocol(result)["view"]["status"] == "done"
    assert {:error, :renderer_value_forbidden} = Result.new(view: %{ansi: "red"})
    assert {:error, :renderer_value_forbidden} = Result.new(view: %{nested: [self()]})
    assert {:error, :renderer_value_forbidden} = Result.new(view: [make_ref()])
    assert {:error, :renderer_value_forbidden} = Result.new(view: fn -> :renderer end)

    assert {:ok, mixed} = Result.new(view: %{"count" => 1, status: "done"})
    assert Result.to_protocol(mixed)["view"] == %{"status" => "done", "count" => 1}
  end
end
