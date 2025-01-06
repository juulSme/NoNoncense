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
      Generate globally unique nonces in distributed Elixir
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
        extras: ~w(./README.md ./LICENSE.md),
        main: "readme",
        skip_undefined_reference_warnings_on: ~w()
      ]
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
      {:benchee, "~> 1.0", only: [:dev], runtime: false}
    ]
  end
end
