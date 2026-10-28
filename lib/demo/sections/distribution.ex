defmodule Demo.Sections.Distribution do
  @moduledoc """
  Distribution is built into the VM: PIDs, messages, monitors and links work
  the same whether a process is local or on another machine.
  """
  import Demo.Fmt
  alias Demo.Cluster

  @peers [:alpha, :bravo, :charlie]

  def run do
    header(3, "Distribution: a cluster of BEAM nodes")

    peers = boot_cluster()
    nodes = Enum.map(peers, &elem(&1, 1))

    transparent_messaging(nodes)
    remote_calls(nodes)
    distributed_work(nodes)
    global_registry(nodes)
    process_groups(nodes)
    node_failure(peers)

    for {peer, _} <- peers, Process.alive?(peer), do: :peer.stop(peer)
    ok("cluster shut down")
  end

  defp boot_cluster do
    step("Starting #{length(@peers)} extra Erlang VMs and connecting them")
    Cluster.ensure_distributed!()
    info("this node: #{hl(node())}")

    {us, peers} = :timer.tc(fn -> Enum.map(@peers, &Cluster.start_peer/1) end)

    for {_, n} <- peers, do: ok("#{hl(n)} is up (OS pid #{:erpc.call(n, System, :pid, [])})")
    note("booted in #{ms(us)}; Node.list() = #{inspect(Node.list())}")
    peers
  end

  defp transparent_messaging(nodes) do
    step("Spawning a process on every node and messaging it like a local one")
    me = self()

    for n <- nodes do
      pid =
        Node.spawn(n, fn ->
          receive do
            {:hello, from} -> send(from, {:hi, node(), self()})
          end
        end)

      send(pid, {:hello, me})
    end

    for _ <- nodes do
      receive do
        {:hi, n, pid} -> ok("#{inspect(pid)} on #{hl(n)} replied")
      end
    end

    note("a PID encodes its node — send/2 just works across the network")

    step("Remote output: IO from a remote process lands in *our* terminal")
    [n | _] = nodes
    Node.spawn(n, fn -> IO.puts("  👋 printed by #{inspect(self())} running on #{node()}") end)
    Process.sleep(100)
    note("the remote process inherits our group leader, so its stdout is forwarded here")
  end

  defp remote_calls(nodes) do
    step("Remote procedure calls with :erpc.multicall")
    results = :erpc.multicall(nodes, :erlang, :memory, [:total])

    for {n, {:ok, mem}} <- Enum.zip(nodes, results) do
      info("#{hl(n)} is using #{bytes(mem)} of memory")
    end
  end

  defp distributed_work(nodes) do
    total = 3_000_000
    chunks = 12

    step(
      "Counting primes below #{num(total)}: #{chunks} chunks spread round-robin over the cluster"
    )

    size = div(total, chunks)

    {us, results} =
      :timer.tc(fn ->
        0..(chunks - 1)
        |> Enum.map(fn i ->
          n = Enum.at(nodes, rem(i, length(nodes)))
          range = (i * size + 1)..((i + 1) * size)
          Task.Supervisor.async({Demo.TaskSup, n}, Demo.Work, :count_primes, [range])
        end)
        |> Task.await_many(30_000)
      end)

    for {n, a..b//_, c} <- results do
      info(
        "#{String.pad_leading(num(a), 9)} … #{String.pad_trailing(num(b), 9)} → #{String.pad_leading(num(c), 6)} primes  on #{n}"
      )
    end

    ok("total #{hl(num(Enum.sum(Enum.map(results, &elem(&1, 2)))))} primes in #{ms(us)}")
    note("{Demo.TaskSup, node} addresses a supervisor on another node by name")
  end

  defp global_registry([a, b, c]) do
    step("A cluster-wide singleton registered with :global")
    {:ok, pid} = :erpc.call(b, Demo.Counter, :start, [])
    info("Demo.Counter started on #{hl(node(pid))} as #{inspect(pid)}")

    for caller <- [node(), a, c, a] do
      {value, host, from} = :erpc.call(caller, Demo.Counter, :incr, [10])
      ok("#{from} incremented it → #{hl(value)} (state lives on #{host})")
    end

    note("callers only know the name {:global, Demo.Counter}, not where it runs")
  end

  defp process_groups(nodes) do
    step("Process groups with :pg — one broadcast, every member answers")

    members =
      for n <- [node() | nodes], _ <- 1..2, do: :erpc.call(n, Demo.Listener, :start, [:chat])

    wait_until(fn -> length(:pg.get_members(:chat)) == length(members) end)

    info(
      ":pg.get_members(:chat) sees #{hl(length(members))} processes on #{length(nodes) + 1} nodes"
    )

    for pid <- :pg.get_members(:chat), do: send(pid, {:broadcast, self(), "hello cluster"})

    acks =
      for _ <- members do
        receive do
          {:ack, n, _pid, reply} -> {n, reply}
        end
      end

    for {{n, reply}, count} <- acks |> Enum.frequencies() |> Enum.sort() do
      ok("#{count} × #{inspect(reply)} from #{hl(n)}")
    end
  end

  defp node_failure(peers) do
    step("Node failure: monitors work across the network")
    :ok = :net_kernel.monitor_nodes(true)

    pid = :global.whereis_name(Demo.Counter)
    {victim_peer, victim} = Enum.find(peers, fn {_, n} -> n == node(pid) end)
    ref = Process.monitor(pid)
    info("monitoring Demo.Counter #{inspect(pid)} on #{hl(victim)}")

    bad("pulling the plug on #{victim}…")
    :peer.stop(victim_peer)

    receive do
      {:nodedown, ^victim} -> ok("got {:nodedown, #{victim}}")
    end

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        ok("got :DOWN for the counter, reason #{hl(inspect(reason))}")
    end

    wait_until(fn -> :global.whereis_name(Demo.Counter) == :undefined end)
    info(":global has already forgotten the dead name")

    step("Failing over: restart the singleton on a surviving node")
    survivor = peers |> Enum.map(&elem(&1, 1)) |> Enum.find(&(&1 != victim))
    {:ok, new_pid} = :erpc.call(survivor, Demo.Counter, :start, [])
    {value, host, _} = Demo.Counter.incr()
    ok("Demo.Counter is back as #{inspect(new_pid)} on #{hl(host)}, value #{value}")
    note("same name, same API — callers didn't change. Libraries like Horde automate this.")
    info("remaining cluster: #{inspect(Node.list())}")

    :net_kernel.monitor_nodes(false)
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        raise "condition never became true"

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end
end
