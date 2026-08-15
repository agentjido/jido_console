defmodule Jido.Console.Release.IdentityTest do
  use ExUnit.Case, async: true

  alias Jido.Console.Release.Identity

  test "embeds the Mix project version for startup before the application loads" do
    assert Identity.version() == to_string(Application.spec(:jido_console, :vsn))
  end

  test "reports the product and runtime identity" do
    identity = Identity.current()

    assert identity.product == "jido"
    assert identity.package == "jido_console"
    assert identity.version == Identity.version()
    assert identity.jidoka == to_string(Application.spec(:jidoka, :vsn))
    assert identity.jidoka_ref == Identity.jidoka_ref()
    assert identity.jidoka_ref == Mix.Project.config()[:jidoka_ref]
    assert identity.elixir == System.version()
    assert identity.otp == List.to_string(:erlang.system_info(:otp_release))
  end

  test "accepts application metadata injection" do
    get_key = fn
      :jido_console, :vsn -> ~c"9.8.7"
      :jidoka, :vsn -> ~c"6.5.4"
    end

    assert Identity.version(application_get_key: get_key) == "9.8.7"

    assert %{version: "9.8.7", jidoka: "6.5.4"} =
             Identity.current(application_get_key: get_key)
  end

  test "production source has no second product version literal" do
    root = Path.expand("../../..", __DIR__)

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

  test "Mix project and OTP application use the jido_console identity" do
    assert Mix.Project.config()[:app] == :jido_console
    assert Mix.Project.config()[:name] == "Jido Console"
    assert Mix.Project.config()[:escript][:name] == "jido"
    assert Mix.Project.config()[:escript][:main_module] == Jido.Console
    assert Application.spec(:jido_console, :vsn)
    refute Application.spec(:jido_cli, :vsn)
  end

  test "release launcher keeps the jido executable and new entry module" do
    launcher = Path.expand("../../../rel/bin/jido", __DIR__)
    source = File.read!(launcher)

    assert source =~ ~r/-s Elixir\.Jido\.Console\.Release\.Entry main/
    refute source =~ "Jido.Cli"
    refute source =~ "jido_cli"
  end

  test "production paths have no stale jido_cli identity" do
    root = Path.expand("../../..", __DIR__)

    matches =
      production_identity_files(root)
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> stale_identity_hits()
        |> Enum.map(&{Path.relative_to(path, root), &1})
      end)

    assert matches == []
  end

  defp production_identity_files(root) do
    (Path.wildcard(Path.join(root, "lib/**/*.{ex,exs}")) ++
       Path.wildcard(Path.join(root, "config/**/*.{ex,exs}")) ++
       Path.wildcard(Path.join(root, "rel/**/*")) ++
       [Path.join(root, "mix.exs")])
    |> Enum.filter(&File.regular?/1)
  end

  defp stale_identity_hits(source) do
    [
      ~r/\bJido\.Cli\b/,
      ~r/:jido_cli\b/,
      ~r/\bjido_cli\b/,
      ~r/\bJido CLI\b/,
      ~r/\bJIDO_CLI_[A-Z_]+\b/
    ]
    |> Enum.flat_map(fn regex ->
      regex
      |> Regex.scan(source)
      |> Enum.map(&List.first/1)
    end)
  end
end
