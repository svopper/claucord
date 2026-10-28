defmodule Mix.Tasks.Chat do
  @shortdoc "Runs the cluster-wide chat server"
  @moduledoc """
  Starts the chat web UI on this node, optionally with more nodes.

      mix chat                        # one node, http://localhost:4000
      mix chat --nodes 3              # this node plus 2 peer VMs on :4001 and :4002
      mix chat --port 4001 --join 4000   # in a second terminal: join an existing node
      mix chat --host 127.0.0.1       # only reachable from this machine

  Each node also serves HTTPS on its port + 443 (4443, 4444, …) with a
  self-signed certificate, because browsers only allow the microphone (voice
  chat) on localhost or over HTTPS.

  The web UI listens on all interfaces (`--host 0.0.0.0`) by default, so other
  devices on your network can join. Erlang distribution between the nodes
  always stays on localhost.

  Every node serves the UI. Users on different nodes chat together.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} =
      OptionParser.parse!(
        args,
        strict: [port: :integer, nodes: :integer, join: :integer, host: :string]
      )

    port = opts[:port] || 4000
    host = opts[:host] || "0.0.0.0"

    ip =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, ip} ->
          ip

        {:error, _} ->
          Mix.raise("--host must be an IP address like 0.0.0.0, got #{inspect(host)}")
      end

    Mix.Task.run("app.start")
    Logger.configure(level: :warning)
    Demo.Cluster.ensure_distributed!(Demo.Chat.node_name(port))
    migrate!()

    cert = Demo.Chat.Cert.ensure!(["localhost", "127.0.0.1" | Demo.Chat.lan_ips(ip)])
    tls = fn http_port -> Map.put(cert, :port, http_port + 443) end

    :ok = Demo.Chat.start(port, ip, tls.(port))
    say(node(), port, ip)

    if join = opts[:join] do
      target = Demo.Chat.node_name(join)
      Node.connect(target) || Mix.raise("could not reach #{target}. Is it running?")
      IO.puts("  joined the cluster via #{target}")
    end

    extra = max((opts[:nodes] || 1) - 1, 0)
    if extra > 0, do: Application.put_env(:demo, :chat_primary, true)

    for i <- 1..extra//1 do
      peer_port = port + i
      {_peer, n} = Demo.Cluster.start_peer(:"chat#{peer_port}", link: false)
      :ok = :erpc.call(n, Demo.Chat, :start, [peer_port, ip, tls.(peer_port)])
      say(n, peer_port, ip)
    end

    unless IEx.started?(), do: Process.sleep(:infinity)
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

  defp say(node, port, ip) do
    urls =
      ["http://localhost:#{port}"] ++
        for lan_ip <- Demo.Chat.lan_ips(ip), do: "https://#{lan_ip}:#{port + 443}"

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
