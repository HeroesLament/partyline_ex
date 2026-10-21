defmodule Partyline.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/HeroesLament/partyline_ex"

  def project do
    [
      app: :partyline_ex,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  # Library, not an OTP application. The consuming app supervises the
  # RNS runtime and whatever combination of clients and servers it runs.
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      # Reticulum substrate: GenLink, GenDestination, announces, paths.
      # RNS_PATH points at another checkout (a worktree on a branch).
      {:rns, path: System.get_env("RNS_PATH", "../reticulum_ex")},

      # Partyline's wire format is msgpack maps with integer keys.
      {:msgpax, "~> 2.4"},

      # Same bz2_ex override as rrc_ex: the Hex 0.1.1 release shipped an
      # empty checksum file, so the precompiled NIF fails verification.
      {:rustler, ">= 0.0.0", optional: true},
      {:bz2_ex, path: "../bz2_ex", override: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Partyline group voice protocol over Reticulum, client and server,
    built on reticulum_ex. Wire compatible with RFnexus/partyline
    (protocol version 1).
    """
  end

  defp package do
    [
      licenses: ["MIT", "Apache-2.0"],
      links: %{"GitHub" => @source_url, "Partyline" => "https://github.com/RFnexus/partyline"},
      files: ~w(lib examples mix.exs README.md LICENSE.md LICENSE-MIT LICENSE-APACHE)
    ]
  end

  defp docs do
    [
      main: "Partyline",
      source_ref: "v#{@version}",
      extras: ["README.md"],
      groups_for_modules: [
        Transport: [
          Partyline.Transport,
          Partyline.Transport.Link,
          Partyline.Transport.Listener,
          Partyline.Transport.Announce
        ],
        Adapters: [
          Partyline.Transport.RNS,
          Partyline.Transport.Loopback
        ]
      ]
    ]
  end
end
