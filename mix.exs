defmodule Jido.Cli.MixProject do
  @moduledoc false

  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mikehostetler/jido_cli"
  @description "Terminal and automation harness for the Jidoka agent framework."
  @jidoka_ref "23bd10ffc822935c06395e34301d63c249e5cbe3"

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
        include_priv_for: [:extractous_ex, :llm_db, :req_llm, :time_zone_info]
      ],
      name: "Jido CLI",
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      releases: releases(),
      package: package(),
      docs: docs(),
      cli: cli(),
      aliases: aliases(),
      test_coverage: [
        tool: ExCoveralls,
        export: "cov"
      ],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: extra_applications(Mix.env())
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_env), do: ["lib"]

  defp extra_applications(env) when env in [:dev, :test], do: [:logger, :mix]
  defp extra_applications(_env), do: [:logger]

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
      files: ~w(lib guides mix.exs README.md LICENSE CHANGELOG.md CONTRIBUTING.md usage-rules.md),
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
        "guides/extensions.md",
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
      jidoka_dep(),
      {:dotenvy, "~> 1.1"},
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

  defp jidoka_dep do
    case System.get_env("JIDO_CLI_JIDOKA_PATH") do
      nil ->
        {:jidoka, github: "agentjido/jidoka", ref: @jidoka_ref}

      path ->
        if Mix.env() in [:dev, :test] do
          {:jidoka, path: Path.expand(path)}
        else
          raise "JIDO_CLI_JIDOKA_PATH is permitted only in development and test"
        end
    end
  end

  # ReqLLM owns llm_db as an included application. The explicit release mode
  # resolves Jidoka's transitive regular-application declaration without
  # editing compiled dependency metadata.
  defp releases do
    [
      jido: [
        applications: [jido_cli: :load, llm_db: :load]
      ]
    ]
  end
end
