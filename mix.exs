defmodule Jido.Cli.MixProject do
  @moduledoc false

  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mikehostetler/jido_cli"
  @description "Terminal and automation harness for the Jidoka agent framework."

  def project do
    [
      app: :jido_cli,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      escript: [
        main_module: Jido.Cli,
        name: "jido",
        app: nil,
        include_priv_for: [:llm_db, :req_llm, :time_zone_info]
      ],
      name: "Jido CLI",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
      cli: cli(),
      aliases: aliases(),
      test_coverage: [
        tool: ExCoveralls,
        summary: [threshold: 80],
        export: "cov"
      ],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.github": :test,
        "coveralls.html": :test
      ]
    ]
  end

  defp package do
    [
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md CONTRIBUTING.md usage-rules.md),
      maintainers: ["Mike Hostetler"],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://hexdocs.pm/jido_cli/changelog.html",
        "Discord" => "https://jido.run/discord",
        "Documentation" => "https://hexdocs.pm/jido_cli",
        "GitHub" => @source_url,
        "Website" => "https://jido.run"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md"
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      install_hooks: ["git_hooks.install"],
      test: ["test --exclude flaky"],
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --min-priority higher",
        "dialyzer",
        "doctor --raise"
      ]
    ]
  end

  defp deps do
    [
      {:jidoka, path: "../jidoka"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:zoi, "~> 0.18"},
      {:splode, "~> 0.3.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false}
    ]
  end
end
