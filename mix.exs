defmodule NoNoncense.MixProject do
  use Mix.Project

  def project do
    [
      app: :no_noncense,
      version: "0.0.0+development",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: """
      Generate locally unique nonces in distributed Elixir
      """,
      package: [
        licenses: ["Apache-2.0"],
        links: %{github: "https://github.com/juulSme/NoNoncense"},
        source_url: "https://github.com/juulSme/NoNoncense"
      ],
      source_url: "https://github.com/juulSme/NoNoncense",
      name: "NoNoncense",
      docs: [
        source_ref: ~s(main),
        extras: ~w(./README.md ./CHANGELOG.md ./MIGRATION.md ./LICENSE.md),
        main: "NoNoncense",
        skip_undefined_reference_warnings_on: ~w()
      ],
      test_ignore_filters: ["test/test_conflict_guard.ex"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.36", only: [:dev, :test], runtime: false},
      {:benchmark, github: "juulSme/benchmark_ex", only: [:dev, :test]},
      {:speck_ex, "~> 0.0.1-beta5", optional: true},
      {:redix, "~> 1.0", optional: true, only: [:test]}
    ]
  end
end
