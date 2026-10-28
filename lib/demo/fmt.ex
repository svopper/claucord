defmodule Demo.Fmt do
  @moduledoc "Tiny helpers for pretty terminal output."

  def header(n, title) do
    line = String.duplicate("━", 64)

    IO.puts([
      "\n",
      IO.ANSI.magenta(),
      line,
      "\n ",
      IO.ANSI.bright(),
      "#{n}. #{title}",
      IO.ANSI.normal(),
      "\n",
      line,
      IO.ANSI.reset()
    ])
  end

  def step(text), do: IO.puts([IO.ANSI.cyan(), "\n▸ ", text, IO.ANSI.reset()])
  def info(text), do: IO.puts(["  ", text])
  def ok(text), do: IO.puts([IO.ANSI.green(), "  ✔ ", IO.ANSI.reset(), text])
  def bad(text), do: IO.puts([IO.ANSI.red(), "  ✘ ", IO.ANSI.reset(), text])
  def note(text), do: IO.puts([IO.ANSI.faint(), "  # ", text, IO.ANSI.reset()])

  def num(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def ms(microseconds), do: "#{Float.round(microseconds / 1000, 1)} ms"

  def bytes(b) when b < 1024, do: "#{b} B"
  def bytes(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)} KB"
  def bytes(b), do: "#{Float.round(b / 1024 / 1024, 1)} MB"

  def hl(term), do: [IO.ANSI.yellow(), to_string(term), IO.ANSI.reset()]
end
