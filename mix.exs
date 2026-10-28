defmodule Demo.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.14"},
      {:websock_adapter, "~> 0.7.0"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22.4"}
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Demo.Application, []}
    ]
  end
end
