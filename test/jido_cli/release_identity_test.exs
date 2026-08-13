defmodule Jido.Cli.ReleaseIdentityTest do
  use ExUnit.Case, async: true

  alias Jido.Cli.ReleaseIdentity

  test "embeds the Mix project version for startup before the application loads" do
    assert ReleaseIdentity.version() == to_string(Application.spec(:jido_cli, :vsn))
  end

  test "reports the product and runtime identity" do
    identity = ReleaseIdentity.current()

    assert identity.product == "jido"
    assert identity.package == "jido_cli"
    assert identity.version == ReleaseIdentity.version()
    assert identity.jidoka == to_string(Application.spec(:jidoka, :vsn))
    assert identity.elixir == System.version()
    assert identity.otp == List.to_string(:erlang.system_info(:otp_release))
  end

  test "accepts application metadata injection" do
    get_key = fn
      :jido_cli, :vsn -> ~c"9.8.7"
      :jidoka, :vsn -> ~c"6.5.4"
    end

    assert ReleaseIdentity.version(application_get_key: get_key) == "9.8.7"

    assert %{version: "9.8.7", jidoka: "6.5.4"} =
             ReleaseIdentity.current(application_get_key: get_key)
  end

  test "production source has no second product version literal" do
    root = Path.expand("../..", __DIR__)

    matches =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        ~r/\b\d+\.\d+\.\d+\b/
        |> Regex.scan(File.read!(path))
        |> Enum.map(fn [version] -> {Path.relative_to(path, root), version} end)
      end)

    assert matches == []
  end
end
