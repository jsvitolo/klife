defmodule Klife.MixProject do
  use Mix.Project

  def project do
    [
      app: :klife,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Klife.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:klife_protocol, "~> 0.1.0"},
      # Benchmarks and tests
      {:benchee, "~> 1.0", only: :dev, runtime: false},
      # Used to wait for connection in tests
      {:retry, "~> 0.18", only: :test}
    ]
  end
end
