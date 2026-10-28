defmodule Demo.Cluster do
  @moduledoc """
  Turns this VM into a distributed node and boots more Erlang VMs on this
  machine with `:peer`, giving `mix chat --nodes N` a cluster without any extra
  terminals.
  """

  # Only for nodes that stay on 127.0.0.1. Anything reachable from another
  # machine must use a secret cookie: whoever knows it can run any code here.
  @dev_cookie :elixir_demo_cookie
  @host ~c"127.0.0.1"

  def dev_cookie, do: @dev_cookie

  @doc """
  Turns the current VM into a distributed node (if it is not already).

  Options:
    * `:ip` - the interface Erlang distribution listens on (default 127.0.0.1)
    * `:ports` - `{min, max}` port range for distribution, so firewalls can
      allow exactly that (default: any free port)
    * `:cookie` - the cluster's shared secret
  """
  def ensure_distributed!(name, opts \\ []) do
    unless Node.alive?() do
      # Distribution needs the Erlang port mapper daemon to be running.
      {_, 0} = System.cmd(System.find_executable("epmd") || "epmd", ["-daemon"])
      Application.put_env(:kernel, :inet_dist_use_interface, opts[:ip] || {127, 0, 0, 1})

      with {min, max} <- opts[:ports] do
        Application.put_env(:kernel, :inet_dist_listen_min, min)
        Application.put_env(:kernel, :inet_dist_listen_max, max)
      end

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

    Node.set_cookie(opts[:cookie] || @dev_cookie)
  end

  defp name_taken?(short_name) do
    case :erl_epmd.names(@host) do
      {:ok, names} -> Enum.any?(names, fn {n, _port} -> List.to_string(n) == short_name end)
      _ -> false
    end
  end

  @doc """
  Starts a peer VM, loads our code into it and starts the :demo app there.

  The peer is not linked to the caller, so a node can be halted (`/halt`)
  without taking the node that started it down too.
  """
  def start_peer(name) do
    {:ok, peer, node} =
      :peer.start(%{
        name: name,
        host: @host,
        longnames: true,
        args: [
          ~c"-setcookie",
          Atom.to_charlist(Node.get_cookie()),
          # Same as for the main node: distribution stays on localhost.
          ~c"-kernel",
          ~c"inet_dist_use_interface",
          ~c"{127,0,0,1}"
        ]
      })

    # Same compiled .beam files on every node: code paths are all it takes.
    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    :ok = :erpc.call(node, Logger, :configure, [[level: :none]])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:demo])
    {peer, node}
  end
end
