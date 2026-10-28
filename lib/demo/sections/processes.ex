defmodule Demo.Sections.Processes do
  @moduledoc """
  BEAM processes are not OS threads: they are tiny, isolated, preemptively
  scheduled and only communicate by sending messages.
  """
  import Demo.Fmt

  @count 200_000
  @ring_size 10_000
  @laps 10

  def run do
    header(1, "Lightweight processes & message passing")

    spawn_many()
    ring()
    selective_receive()
  end

  defp spawn_many do
    step("Spawning #{num(@count)} processes, each waiting for a message")
    parent = self()
    mem_before = :erlang.memory(:processes)

    {spawn_us, pids} =
      :timer.tc(fn ->
        for i <- 1..@count do
          spawn(fn ->
            receive do
              :ping -> send(parent, {:pong, i * i})
            end
          end)
        end
      end)

    mem_used = :erlang.memory(:processes) - mem_before
    ok("spawned in #{hl(ms(spawn_us))}")
    ok("~#{hl(bytes(div(mem_used, @count)))} of memory per process")
    info("schedulers (one per CPU core): #{hl(System.schedulers_online())}")

    step("Pinging every one of them and summing the squares they send back")

    {us, sum} =
      :timer.tc(fn ->
        Enum.each(pids, &send(&1, :ping))
        collect(@count, 0)
      end)

    ok("#{num(@count)} round trips in #{hl(ms(us))}, sum = #{num(sum)}")
  end

  defp collect(0, acc), do: acc

  defp collect(n, acc) do
    receive do
      {:pong, v} -> collect(n - 1, acc + v)
    end
  end

  # Classic Erlang benchmark: N processes in a ring pass a token around M times.
  defp ring do
    step("Ring: #{num(@ring_size)} processes pass a token around #{@laps} times")

    {us, :done} =
      :timer.tc(fn ->
        first =
          Enum.reduce(1..(@ring_size - 1), self(), fn _, next -> spawn(fn -> relay(next) end) end)

        send(first, {:token, @laps * @ring_size})
        ring_head(first)
      end)

    ok("#{num(@ring_size * @laps)} messages hopped in #{hl(ms(us))}")
  end

  # When the token runs out, a :stop message travels the ring once so every
  # process exits cleanly.
  defp relay(next) do
    receive do
      {:token, 0} ->
        send(next, :stop)
        relay(next)

      {:token, n} ->
        send(next, {:token, n - 1})
        relay(next)

      :stop ->
        send(next, :stop)
    end
  end

  # The calling process is the last link in the ring.
  defp ring_head(first) do
    receive do
      {:token, 0} ->
        send(first, :stop)
        ring_head(first)

      {:token, n} ->
        send(first, {:token, n - 1})
        ring_head(first)

      :stop ->
        send(first, :stop)
        :done
    end
  end

  defp selective_receive do
    step("Pattern matching on messages (selective receive)")
    send(self(), {:log, "low priority"})
    send(self(), {:alert, :disk_full})
    send(self(), {:log, "another"})

    receive do
      {:alert, what} -> ok("picked #{hl(inspect({:alert, what}))} out of the mailbox first")
    end

    {:messages, rest} = Process.info(self(), :messages)
    note("still queued, in order: #{inspect(rest)}")
    flush()
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
