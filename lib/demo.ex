defmodule Demo do
  @moduledoc """
  A tour of what makes Elixir (and the BEAM) special.

      mix demo                 # run everything
      mix demo distribution    # run one section
  """
  alias Demo.Sections

  @sections %{
    "processes" => Sections.Processes,
    "fault_tolerance" => Sections.FaultTolerance,
    "distribution" => Sections.Distribution
  }
  @order ["processes", "fault_tolerance", "distribution"]

  def run(names \\ []) do
    # Crash reports are expected (we crash things on purpose); keep output tidy.
    Logger.configure(level: :none)

    names = if names == [], do: @order, else: names

    for name <- names do
      case Map.fetch(@sections, name) do
        {:ok, mod} ->
          mod.run()

        :error ->
          Mix.raise("unknown section #{inspect(name)}, pick from: #{Enum.join(@order, ", ")}")
      end
    end

    IO.puts([IO.ANSI.green(), IO.ANSI.bright(), "\n✨ Done.\n", IO.ANSI.reset()])
  end
end
