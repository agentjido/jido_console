defmodule Jido.Console.Session.Durable.ValueTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Durable.Value

  test "structural credential, runtime, and nonportable values return redacted errors" do
    cases = [
      %{"arguments" => ["${SERVICE_TOKEN}"]},
      %{"event" => %URI{}},
      %{"event" => make_ref()},
      %{"event" => {:not, :portable}},
      %{1 => "invalid key"}
    ]

    for candidate <- cases do
      assert {:error, {:sensitive_value_rejected, details}} = Value.validate(candidate)
      assert details["redacted"] == true
    end
  end
end
