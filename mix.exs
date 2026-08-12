defmodule Jido.Cli.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :jido_cli,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      escript: [
        main_module: Jido.Cli,
        name: "jido",
        app: nil,
        include_priv_for: [:llm_db, :req_llm, :time_zone_info]
      ],
      test_coverage: [summary: [threshold: 90]],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:jidoka, "~> 0.8.0-beta.1"},
      {:yaml_elixir, "~> 2.12"}
    ]
  end
end
