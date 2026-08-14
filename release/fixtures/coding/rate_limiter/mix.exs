defmodule RateLimiterScenario.MixProject do
  use Mix.Project

  def project do
    [
      app: :rate_limiter_scenario,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
