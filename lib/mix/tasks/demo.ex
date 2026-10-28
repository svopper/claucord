defmodule Mix.Tasks.Demo do
  @shortdoc "Runs the Elixir feature tour"
  @moduledoc "Usage: `mix demo [processes | fault_tolerance | distribution ...]`"
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    Demo.run(args)
  end
end
