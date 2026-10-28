defmodule Mix.Tasks.Chat do
  @shortdoc "Runs the cluster-wide chat server"
  @moduledoc """
  Starts the chat on this node, optionally with more nodes.

  On one machine:

      mix chat                        # one node, http://localhost:4000
      mix chat --nodes 3              # this node plus 2 peer VMs on :4001 and :4002
      mix chat --port 4001 --join 4000   # in a second terminal: join an existing node
      mix chat --host 127.0.0.1       # web UI only reachable from this machine

  Across machines (see docs/DEPLOYMENT.md), every option can also be set with
  the environment variable in brackets:

      --name chat@100.64.0.1        node name; the host part is how other nodes reach it [CHAT_NODE_NAME]
      --dist-ip 100.64.0.1          interface for node-to-node traffic (default: the
                                    name's IP, or 127.0.0.1) [CHAT_DIST_IP]
      --dist-ports 9100-9105        port range for node-to-node traffic [CHAT_DIST_PORTS]
      --join chat@100.64.0.2        node(s) to connect to, comma-separated; retried until
                                    reachable [CHAT_JOIN]
      --public-url https://a.chat.example.com
                                    how browsers reach this node [CHAT_PUBLIC_URL]
      --no-https                    don't serve the self-signed HTTPS port (behind a
                                    proxy that does TLS) [CHAT_HTTPS=false]

  A node reachable from other machines needs a secret cookie in CHAT_COOKIE.

  By default each node also serves HTTPS on its port + 443 (4443, 4444, …) with
  a self-signed certificate, because browsers only allow the microphone (voice
  chat) on localhost or over HTTPS.
  """
  use Mix.Task

  @switches [
    port: :integer,
    nodes: :integer,
    join: :string,
    host: :string,
    name: :string,
    dist_ip: :string,
    dist_ports: :string,
    public_url: :string,
    https: :boolean
  ]

  @default_dist_ports {9100, 9105}

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)

    port = opts[:port] || 4000
    ip = parse_ip!(opts[:host] || "0.0.0.0", "--host")
    name = node_name!(opt(opts, :name, "CHAT_NODE_NAME"), port)
    dist_ip = dist_ip!(opt(opts, :dist_ip, "CHAT_DIST_IP"), name)
    local? = match?({127, _, _, _}, dist_ip)
    cookie = cookie!(local?)
    join = join!(opt(opts, :join, "CHAT_JOIN"))
    public_url = public_url!(opt(opts, :public_url, "CHAT_PUBLIC_URL"))
    https? = Keyword.get(opts, :https, System.get_env("CHAT_HTTPS") not in ~w(false 0 no off))
    extra = max((opts[:nodes] || 1) - 1, 0)

    if extra > 0 and not local? do
      Mix.raise(
        "--nodes starts extra nodes on this machine only; run one node per machine instead"
      )
    end

    case Demo.Chat.Config.problems() do
      [] -> :ok
      problems -> Mix.raise(Enum.join(problems, "\n"))
    end

    ports =
      case opt(opts, :dist_ports, "CHAT_DIST_PORTS") do
        nil -> if local?, do: nil, else: @default_dist_ports
        range -> port_range!(range)
      end

    Mix.Task.run("app.start")
    Logger.configure(level: :warning)
    Demo.Cluster.ensure_distributed!(name, ip: dist_ip, ports: ports, cookie: cookie)
    migrate!()

    tls =
      if https? do
        cert = Demo.Chat.Cert.ensure!(["localhost", "127.0.0.1" | Demo.Chat.lan_ips(ip)])
        fn http_port -> Map.put(cert, :port, http_port + 443) end
      else
        fn _ -> nil end
      end

    :ok = Demo.Chat.start(port: port, ip: ip, tls: tls.(port), public_url: public_url, join: join)
    say(node(), port, ip, https?, public_url)
    if join != [], do: IO.puts("  joining #{Enum.join(join, ", ")} (retries until reachable)")

    # Voice and video go browser to browser. Between two different networks
    # (a friend connecting over the internet) that needs a TURN server.
    if ip != {127, 0, 0, 1} and Demo.Chat.Config.ice_servers("check") == [] do
      IO.puts([
        IO.ANSI.yellow(),
        "  note: no TURN server set, so voice/video only works between devices on the same\n",
        "        network. For people connecting over the internet, see \"Voice over the internet\"\n",
        "        in the README.",
        IO.ANSI.reset()
      ])
    end

    if extra > 0, do: Application.put_env(:demo, :chat_primary, true)

    for i <- 1..extra//1 do
      peer_port = port + i
      {_peer, n} = Demo.Cluster.start_peer(:"chat#{peer_port}")
      :ok = :erpc.call(n, Demo.Chat, :start, [[port: peer_port, ip: ip, tls: tls.(peer_port)]])
      say(n, peer_port, ip, https?, nil)
    end

    unless IEx.started?(), do: Process.sleep(:infinity)
  end

  defp opt(opts, key, env) do
    case opts[key] || System.get_env(env) do
      value when value in [nil, ""] -> nil
      value -> String.trim(value)
    end
  end

  defp node_name!(nil, port), do: Demo.Chat.node_name(port)

  defp node_name!(name, _port) do
    case String.split(name, "@") do
      [short, host] when short != "" and host != "" -> String.to_atom(name)
      _ -> Mix.raise("--name must look like chat@100.64.0.1, got #{inspect(name)}")
    end
  end

  # Where node-to-node traffic listens: given explicitly, or the node name's
  # host if that is an IP address. Never guessed beyond that, because
  # listening on the wrong interface could expose the node to the internet.
  defp dist_ip!(nil, name) do
    host = name |> Atom.to_string() |> String.split("@") |> List.last()

    case {host, :inet.parse_address(String.to_charlist(host))} do
      {_, {:ok, ip}} ->
        ip

      {"localhost", _} ->
        {127, 0, 0, 1}

      _ ->
        Mix.raise("""
        Node #{name} uses a hostname, so say which interface node-to-node traffic
        should listen on, e.g. --dist-ip 100.64.0.1 (your private network address).
        """)
    end
  end

  defp dist_ip!(given, _name), do: parse_ip!(given, "--dist-ip")

  defp cookie!(local?) do
    case System.get_env("CHAT_COOKIE") do
      cookie when is_binary(cookie) and byte_size(cookie) >= 20 ->
        String.to_atom(cookie)

      _ when local? ->
        Demo.Cluster.dev_cookie()

      _ ->
        Mix.raise("""
        This node can be reached from other machines, so it needs a secret cookie:
        anyone who knows the cookie can run any code on the node. Set the same
        value on every node, e.g.:

            export CHAT_COOKIE=$(openssl rand -hex 32)
        """)
    end
  end

  # "4000" (a node on this machine) or "chat@100.64.0.2,chat@100.64.0.3".
  defp join!(nil), do: []

  defp join!(value) do
    case Integer.parse(value) do
      {port, ""} ->
        [Demo.Chat.node_name(port)]

      _ ->
        for target <- String.split(value, ",", trim: true) do
          target |> String.trim() |> node_name!(nil)
        end
    end
  end

  defp public_url!(nil), do: nil

  defp public_url!(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        String.trim_trailing(url, "/")

      _ ->
        Mix.raise("--public-url must look like https://a.chat.example.com, got #{inspect(url)}")
    end
  end

  defp port_range!(range) do
    with [min, max] <- String.split(range, "-"),
         {min, ""} <- Integer.parse(min),
         {max, ""} <- Integer.parse(max),
         true <- min <= max do
      {min, max}
    else
      _ -> Mix.raise("--dist-ports must look like 9100-9105, got #{inspect(range)}")
    end
  end

  defp parse_ip!(value, flag) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> ip
      {:error, _} -> Mix.raise("#{flag} must be an IP address, got #{inspect(value)}")
    end
  end

  # Brings the database schema up to date, or explains how to start Postgres.
  defp migrate! do
    Logger.configure(level: :none)
    Demo.Repo.migrate!()
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error] ->
      Mix.raise("""
      Can't reach Postgres at #{redact(Demo.Repo.url())}:
        #{first_sentence(Exception.message(e))}
      Start it with:  docker compose up -d
      (or point DATABASE_URL at another Postgres)
      """)
  after
    Logger.configure(level: :warning)
  end

  # "[Demo.Repo] connection not available and ... after 5990ms. This means ..."
  # -> "connection not available and ... after 5990ms."
  defp first_sentence(message) do
    message
    |> String.replace(~r/^\[[^\]]*\]\s*/, "")
    |> String.split(~r/(?<=\.)\s/, parts: 2)
    |> hd()
  end

  defp redact(url) do
    uri = URI.parse(url)
    user = uri.userinfo |> to_string() |> String.split(":") |> hd()
    URI.to_string(%{uri | userinfo: user})
  end

  defp say(node, port, ip, https?, public_url) do
    urls =
      cond do
        public_url ->
          [public_url]

        https? ->
          ["http://localhost:#{port}"] ++
            for lan_ip <- Demo.Chat.lan_ips(ip), do: "https://#{lan_ip}:#{port + 443}"

        true ->
          ["http://localhost:#{port}"] ++
            for lan_ip <- Demo.Chat.lan_ips(ip), do: "http://#{lan_ip}:#{port}"
      end

    IO.puts([
      "  ",
      IO.ANSI.green(),
      "●",
      IO.ANSI.reset(),
      " #{node}  →  ",
      IO.ANSI.cyan(),
      Enum.join(urls, "  "),
      IO.ANSI.reset()
    ])
  end
end
