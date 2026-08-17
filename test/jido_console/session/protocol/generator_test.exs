defmodule Jido.Console.Session.Protocol.GeneratorTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Session.Protocol
  alias Jido.Console.Session.Protocol.Generator

  test "writes both generated bindings from the canonical schema" do
    root = Path.join(System.tmp_dir!(), "jido-protocol-generator-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, schema} = Protocol.schema()
    assert %{elixir: elixir, typescript: typescript, digest: digest} = Generator.write!(schema, root: root)
    assert digest == Generator.digest()

    elixir_source = File.read!(elixir)
    typescript_source = File.read!(typescript)

    assert {:ok, _quoted} = Code.string_to_quoted(elixir_source)
    assert elixir_source =~ "defmodule Jido.Console.Session.Protocol.Generated"
    assert elixir_source =~ inspect(digest)

    assert typescript_source =~ "export const protocolDigest = #{inspect(digest)}"
    assert typescript_source =~ "export type ProtocolEnvelope ="
    assert typescript_source =~ "export const protocolSensitiveValues ="
    assert typescript_source =~ ~s("sequence": unknown;)
    assert typescript_source =~ ~s("input_id"?: unknown;)

    catalog = Generator.catalog(schema, digest)
    assert catalog["protocol"] == "jido.session"
    assert catalog["families"]["event"]["types"]["input_admitted"]["locality"] == "shared"

    assert catalog["families"]["operation"]["types"]["exact_resume"]["field_values"]["mode"] ==
             ["exact"]

    assert "credential_value" in catalog["sensitive_values"]["forbidden_field_names"]
  end
end
