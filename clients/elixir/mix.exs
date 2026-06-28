defmodule FiduciaClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :fiducia_client,
      version: "0.1.0",
      elixir: "~> 1.16",
      description: "Fiducia HTTP client for Elixir.",
      elixirc_paths: ["."],
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp package do
    [
      files: ["fiducia.ex", "mix.exs"],
      licenses: ["UNLICENSED"],
      links: %{
        "GitHub" => "https://github.com/fiducia-cloud/fiducia-clients/tree/main/clients/elixir"
      }
    ]
  end
end
