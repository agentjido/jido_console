defmodule Jido.Console.MixProject do
  @moduledoc false

  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agentjido/jido_console"
  @description "Terminal and automation harness for the Jidoka agent framework."
  @jidoka_ref "29246d0a762fe1b17f4250e4f5c98c9f3f6d8419"

  def project do
    [
      app: :jido_console,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      escript: [
        main_module: Jido.Console,
        name: "jido",
        app: nil,
        include_priv_for: [:extractous_ex, :req_llm, :time_zone_info]
      ],
      name: "Jido Console",
      description: @description,
      jidoka_ref: @jidoka_ref,
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
      extra_applications: extra_applications(Mix.env()),
      mod: {Jido.Console.Application, []}
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
        "Changelog" => "https://hexdocs.pm/jido_console/changelog.html",
        "Discord" => "https://jido.run/discord",
        "Documentation" => "https://hexdocs.pm/jido_console",
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
        "ROADMAP.md",
        "guides/extensions.md",
        "guides/multi-turn-coding.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "LICENSE"
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      install_hooks: ["git_hooks.install"],
      test: ["test --exclude flaky"],
      q: ["precommit"],
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "xref graph --format cycles --fail-above 0",
        "credo",
        "dialyzer",
        "doctor --raise"
      ]
    ]
  end

  defp deps do
    [
      # Runtime dependencies
      {:dotenvy, "~> 1.1"},
      {:jason, "~> 1.4"},
      jidoka_dep(),
      {:req_llm, "~> 1.20.0"},
      {:splode, "~> 0.3.0"},
      {:yaml_elixir, "~> 2.12"},
      {:zoi, "~> 0.18"},

      # Development and test dependencies
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:git_hooks, "~> 0.8", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false}
    ]
  end

  defp jidoka_dep do
    case System.get_env("JIDO_CONSOLE_JIDOKA_PATH") do
      nil ->
        {:jidoka, github: "agentjido/jidoka", ref: @jidoka_ref}

      path ->
        if Mix.env() in [:dev, :test] do
          {:jidoka, path: Path.expand(path)}
        else
          raise "JIDO_CONSOLE_JIDOKA_PATH is permitted only in development and test"
        end
    end
  end

  # ReqLLM owns llm_db as an included application. The explicit release mode
  # resolves Jidoka's transitive regular-application declaration without
  # editing compiled dependency metadata.
  defp releases do
    [
      jido: [
        applications: [jido_console: :load, llm_db: :load]
      ]
    ]
  end
end
