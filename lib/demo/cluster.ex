defmodule Demo.Cluster do
  @moduledoc """
  Boots real Erlang VMs on this machine with `:peer` and connects them to the
  current node, giving us a cluster without any extra terminals.
  """

  @cookie :elixir_demo_cookie
  @host ~c"127.0.0.1"

  @doc "Turns the current VM into a distributed node (if it is not already)."
  def ensure_distributed!(name \\ :"main@127.0.0.1") do
    unless Node.alive?() do
      # Distribution needs the Erlang port mapper daemon to be running.
      {_, 0} = System.cmd(System.find_executable("epmd") || "epmd", ["-daemon"])
      # The cookie is hard-coded, so never accept distribution connections
      # from other machines: anyone who can connect can run any code here.
      Application.put_env(:kernel, :inet_dist_use_interface, {127, 0, 0, 1})

      case Node.start(name, :longnames) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          [short | _] = name |> Atom.to_string() |> String.split("@")

          if name_taken?(short) do
            Mix.raise("""
            Can't start node #{name}: a node with that name is already running.
            Stop it first (Ctrl+C twice in its terminal, or `pkill -f "mix chat"`).
            Running nodes are listed by `epmd -names`.
            """)
          else
            Mix.raise("Can't start distributed node #{name}: #{inspect(reason)}")
          end
      end
    end

    Node.set_cookie(@cookie)
  end

  defp name_taken?(short_name) do
    case :erl_epmd.names(@host) do
      {:ok, names} -> Enum.any?(names, fn {n, _port} -> List.to_string(n) == short_name end)
      _ -> false
    end
  end

  @doc """
  Starts a peer VM, loads our code into it and starts the :demo app there.

  Pass `link: false` if the peer should be allowed to die without taking the
  caller down with it.
  """
  def start_peer(name, opts \\ []) do
    start = if Keyword.get(opts, :link, true), do: :start_link, else: :start

    {:ok, peer, node} =
      apply(:peer, start, [
        %{
          name: name,
          host: @host,
          longnames: true,
          args: [
            ~c"-setcookie",
            Atom.to_charlist(@cookie),
            # Same as for the main node: distribution stays on localhost.
            ~c"-kernel",
            ~c"inet_dist_use_interface",
            ~c"{127,0,0,1}"
          ]
        }
      ])

    # Same compiled .beam files on every node: code paths are all it takes.
    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    :ok = :erpc.call(node, Logger, :configure, [[level: :none]])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:demo])
    {peer, node}
  end
end

defmodule Demo.Counter do
  @moduledoc "A cluster-wide singleton, registered in :global."
  use GenServer

  @name {:global, __MODULE__}

  def start, do: GenServer.start(__MODULE__, 0, name: @name)
  def incr(by \\ 1), do: GenServer.call(@name, {:incr, by})

  @impl true
  def init(n), do: {:ok, n}

  @impl true
  def handle_call({:incr, by}, {caller, _}, n) do
    {:reply, {n + by, node(), node(caller)}, n + by}
  end
end

defmodule Demo.Listener do
  @moduledoc "Joins a :pg process group and acknowledges broadcasts."

  def start(group) do
    parent = self()

    pid =
      spawn(fn ->
        :ok = :pg.join(group, self())
        send(parent, :joined)
        loop()
      end)

    receive do
      :joined -> pid
    end
  end

  defp loop do
    receive do
      {:broadcast, from, msg} ->
        send(from, {:ack, node(), self(), String.upcase(msg)})
        loop()
    end
  end
end

defmodule Demo.Work do
  @moduledoc "CPU-bound work to hand out across the cluster."

  def count_primes(range), do: {node(), range, Enum.count(range, &prime?/1)}

  defp prime?(n) when n < 2, do: false
  defp prime?(n) when n < 4, do: true
  defp prime?(n) when rem(n, 2) == 0, do: false
  defp prime?(n), do: Enum.all?(3..trunc(:math.sqrt(n))//2, &(rem(n, &1) != 0))
end
