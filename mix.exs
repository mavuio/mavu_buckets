defmodule MavuBuckets.MixProject do
  use Mix.Project

  @version "1.0.1"
  def project do
    [
      app: :mavu_buckets,
      version: @version,
      elixir: "~> 1.0",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      deps: deps(),
      name: "MavuBuckets",
      source_url: "https://github.com/mavuio/mavu_buckets"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MavuBuckets.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
      {:mavu_utils, "~> 1.0"},
      {:accessible, ">= 0.2.0"},
      {:bertex, "~> 1.3"},
      {:ecto, ">= 3.0.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:phoenix_pubsub, "~> 2.1"}
    ]
  end

  defp description() do
    "MavuBuckets: DB-backed Key/Value Storage for mavu_* projects"
  end

  defp package() do
    [
      files: ~w(lib .formatter.exs mix.exs README*),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/mavuio/mavu_buckets"}
    ]
  end
end
