defmodule Jido.Console.PortableValueTest do
  use ExUnit.Case, async: true

  alias Jido.Console.PortableValue

  test "structural credential, runtime, and nonportable values return redacted errors" do
    cases = [
      %{"arguments" => ["${SERVICE_TOKEN}"]},
      %{"event" => %URI{}},
      %{"event" => make_ref()},
      %{"event" => {:not, :portable}},
      %{1 => "invalid key"}
    ]

    for candidate <- cases do
      assert {:error, {:sensitive_value_rejected, details}} = PortableValue.validate(candidate)
      assert details["redacted"] == true
    end
  end

  test "accepts portable scalars, nested lists, atoms, and approved structs" do
    assert :ok = PortableValue.validate(%{"values" => [nil, true, 1, 1.5, "text", :ok]})
    assert :ok = PortableValue.validate(%URI{scheme: "https", host: "example.test"}, allow_struct: &(&1 == URI))
    assert :ok = PortableValue.validate(%{"draft" => "local"}, allow_local_fields: true)
  end

  test "rejects all credential, client-state, and runtime channels" do
    port = Port.open({:spawn, "true"}, [])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    cases = [
      %{"url" => "https://user:password@example.test"},
      %{"uri" => "https://example.test?token=secret"},
      %{"arguments" => "tool --api-key secret"},
      %{"headers" => "${SERVICE_SECRET}"},
      %{"password" => "secret"},
      %{"draft" => "private local state"},
      %{"provider_client" => "raw"},
      %{"event" => self()},
      %{"event" => port},
      %{"event" => fn -> :ok end}
    ]

    for candidate <- cases do
      assert {:error, {:sensitive_value_rejected, %{"redacted" => true}}} = PortableValue.validate(candidate)
    end
  end

  test "stops at the first nested rejection and tolerates malformed URI query data" do
    assert {:error, {:sensitive_value_rejected, details}} =
             PortableValue.validate(%{"metadata" => ["safe", %{"token" => "secret"}, "unused"]})

    assert details["path"] == "metadata.1.token"
    assert :ok = PortableValue.validate(%{"url" => "https://example.test?bad=%ZZ"})
  end
end
