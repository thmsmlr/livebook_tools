defmodule LivebookTools.MixProject do
  use Mix.Project

  def project do
    [
      app: :livebook_tools,
      version: "0.0.1",
      elixir: "~> 1.18",
      escript: escript_config(),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp escript_config do
    [
      main_module: LivebookTools.CLI
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:livebook, "~> 0.15.1", runtime: false}
    ]
  end
end
