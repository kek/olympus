defmodule Olympus.MixProject do
  use Mix.Project

  def project do
    [
      app: :olympus,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [],
      elixirc_paths: ["lib"]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :inets, :ssl], mod: {Olympus.Application, []}]
  end
end
