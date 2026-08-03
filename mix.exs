defmodule Slop.MixProject do
  use Mix.Project

  def project do
    [
      app: :slop,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      escript: [main_module: Slop.CLI, name: "slopc"],
      deps: []
    ]
  end

  def application do
    [extra_applications: [:compiler, :syntax_tools]]
  end
end
