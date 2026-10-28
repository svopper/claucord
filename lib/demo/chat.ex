defmodule Demo.Chat do
  @moduledoc """
  A real-time, cluster-wide chat built only on OTP primitives:

    * every channel is a single GenServer, registered cluster-wide in `:global`
    * messages fan out to `:pg` process groups that span every node
    * presence is derived from `:pg` membership and pushed via `:pg.monitor_scope/1`
    * each browser tab is one WebSocket process (Bandit + WebSock)

  Start it with `mix chat` (see the README).
  """

  @channels [
    {"general", "Say hi! Every node in the cluster sees this channel."},
    {"random", "Anything goes."},
    {"elixir", "Pipes, pattern matching and |> appreciation."},
    {"distributed", "Try /crash and /halt here and watch the cluster heal."}
  ]

  @voice_rooms [{"lounge", "Lounge"}, {"stand-up", "Stand-up"}]

  # The built-in channels. Users can add more; see Demo.Chat.Directory.
  def default_voice_rooms, do: @voice_rooms
  def default_channels, do: @channels

  def node_name(port), do: :"chat#{port}@127.0.0.1"

  @doc "Addresses other devices can use to reach a server listening on `ip`."
  def lan_ips({127, _, _, _}), do: []
  def lan_ips({0, 0, 0, 0}), do: own_ipv4s()
  def lan_ips(ip), do: [to_string(:inet.ntoa(ip))]

  defp own_ipv4s do
    {:ok, ifs} = :inet.getifaddrs()

    for {_name, opts} <- ifs,
        :up in Keyword.get(opts, :flags, []),
        {:addr, {a, _, _, _} = addr} <- opts,
        a != 127 and a != 169 do
      to_string(:inet.ntoa(addr))
    end
    |> Enum.uniq()
  end

  @doc """
  Starts the chat (HTTP server, presence, channel supervisor) on this node.
  `ip` is the interface the web server listens on, e.g. `{0, 0, 0, 0}` for all.
  `tls` (`%{port: _, certfile: _, keyfile: _}`) adds an HTTPS listener.
  """
  def start(port, ip \\ {127, 0, 0, 1}, tls \\ nil) do
    Application.put_env(:demo, :chat_port, port)

    case Supervisor.start_child(Demo.Supervisor, {Demo.Chat.Supervisor, {port, ip, tls}}) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        if inspect(reason) =~ "eaddrinuse" do
          raise "port #{port} or #{tls && tls.port} is already in use; pick another one with --port"
        else
          raise "could not start the chat on port #{port}: #{inspect(reason)}"
        end
    end
  end
end

defmodule Demo.Chat.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(args), do: Supervisor.start_link(__MODULE__, args, name: __MODULE__)

  @impl true
  def init({port, ip, tls}) do
    https =
      if tls do
        bandit =
          {Bandit,
           plug: Demo.Chat.Router,
           scheme: :https,
           ip: ip,
           port: tls.port,
           certfile: tls.certfile,
           keyfile: tls.keyfile}

        [Supervisor.child_spec(bandit, id: :https)]
      else
        []
      end

    children =
      [
        Demo.Repo,
        {DynamicSupervisor,
         name: Demo.Chat.ChannelSup, strategy: :one_for_one, max_restarts: 100},
        Demo.Chat.Directory,
        {Demo.Chat.Presence, {port, tls && tls.port}},
        Demo.Chat.Gifs,
        Supervisor.child_spec({Bandit, plug: Demo.Chat.Router, ip: ip, port: port}, id: :http)
      ] ++ https

    Supervisor.init(children, strategy: :one_for_one)
  end
end
