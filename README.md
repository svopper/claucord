# Elixir demo: processes, fault tolerance and distribution

A self-running tour of the things the BEAM VM does that most runtimes don't, plus a cluster-wide chat app.
The tour has no dependencies (the chat uses Bandit). You need Elixir ≥ 1.18 / OTP ≥ 25 (`brew install elixir`).

```sh
mix demo                    # run every section
mix demo distribution       # or only one: processes | fault_tolerance | distribution
```

## What it shows

| # | Section | Highlights | Code |
|---|---------|-----------|------|
| 1 | **Lightweight processes** | 200k processes spawned in ~0.2 s at ~2.6 KB each; a 10k-process ring benchmark; selective `receive` with pattern matching | `lib/demo/sections/processes.ex` |
| 2 | **Fault tolerance** | A supervisor restarts a crashed GenServer while its sibling keeps running; one failing task doesn't affect the others; links + `trap_exit` | `lib/demo/sections/fault_tolerance.ex` |
| 3 | **Distribution** | Starts 3 extra VMs with `:peer` and then shows: remote `spawn`/`send`, remote IO forwarding, `:erpc.multicall`, prime counting spread over the cluster, a `:global` singleton, `:pg` broadcast groups, cross-node monitors when a node dies, and singleton failover | `lib/demo/sections/distribution.ex`, `lib/demo/cluster.ex` |

The distribution section needs no setup. It makes the current VM a distributed node
(`main@127.0.0.1`), starts `epmd` if needed, and boots the peer nodes `alpha`,
`bravo` and `charlie` on localhost. The same code runs unchanged across real machines.

## BEAM Chat: a cluster-wide chat app

A real-time chat with a Discord-style layout, served by every node in the cluster.
Messages and created channels are stored in Postgres, which runs in Docker:

```sh
docker compose up -d      # Postgres 18 on 127.0.0.1:5433 (data kept in a Docker volume)
mix chat --nodes 3        # chat4000, chat4001, chat4002 on :4000, :4001, :4002
```

`mix chat` creates and updates the tables itself. To use another database, set
`DATABASE_URL`, e.g. `DATABASE_URL=ecto://user:pass@host:5432/db mix chat`. Each
node keeps 2 connections, and the container allows 500.

What's stored: messages, GIFs, system messages and created channels. A channel's
process loads its recent history when it starts, so a crash, a dead node or a full
restart of every node loses nothing. Presence, voice and video are live state, so
they aren't stored.

Open http://localhost:4000 and http://localhost:4001 in two windows, using different names.
The users are connected to different VMs but chat together.

| In the UI | What's behind it |
|-----------|------------------|
| **Server rail** (left): one icon per cluster node, with its user count. Click one to move your connection to that node. | Each node joins a `{:chat_node, port}` `:pg` group |
| **Channels**: messages and history, plus unread badges | One `Demo.Chat.Channel` GenServer per channel for the *whole cluster*, registered in `:global`, started lazily on the first node that needs it. The header pill shows which node runs it. |
| **Members** (right), grouped by node | Presence is just `:pg` membership, pushed live via `:pg.monitor_scope/0`. No heartbeats and no cleanup code. |
| **Typing indicator**, @mentions, `code` and **bold** formatting | Plain Erlang messages to the channel's `:pg` group |
| `/crash` | Crashes the channel process. Its supervisor restarts it and the new process reloads the history from Postgres. Everyone's connection survives. |
| `/halt` | Shuts down the node you're connected to. Its users disappear from presence, and your browser fails over to another node. |
| `/where` | Shows the pid and node of the channel process |
| **Create channels**: the **+** next to "Text channels" or "Voice channels" | The channel list is replicated on every node (`Demo.Chat.Directory`). A new channel is sent to every node, and copies are merged as a set union (a grow-only set, a simple CRDT), so there's no central owner. Channels survive losing the node they were created on, and nodes swap full lists when they connect, so newcomers catch up. |
| **GIF picker** (the GIF button in the message box) | Search goes through the server (`GET /gifs?q=`), so the GIPHY key never reaches browsers. Each node caches results in ETS for 10 minutes. GIF messages are only accepted from GIPHY's media domain. |
| **Voice channels** (Lounge, Stand-up), with speaking rings, mute, deafen, join/leave chimes and **video** (camera button in the voice bar) | Audio goes browser-to-browser over WebRTC. The cluster is the signaling server: who is in a room is a `:pg` group, and offers, answers and ICE candidates are routed to the other person's socket process, whichever node it's on. If your node dies mid-call, your browser fails over and rejoins the room. |

GIF search uses [GIPHY](https://developers.giphy.com/) (Google shut down the
Tenor API in June 2026). Get a free API key there and start the chat with it:

```sh
GIPHY_API_KEY=your-key mix chat --nodes 3
```

Without a key, everything else works and the picker explains how to get one.

You can also run nodes in separate terminals:

```sh
mix chat                          # terminal 1 → :4000
mix chat --port 4001 --join 4000  # terminal 2 → :4001
```

The web UI listens on all interfaces, so phones and laptops on your network can
join through the LAN addresses `mix chat` prints, e.g. `https://192.168.1.20:4443`.

Browsers only allow the microphone on `localhost` or over HTTPS, so every node
also serves HTTPS on its port + 443 (4443, 4444, …). The certificate is
self-signed: accept the browser warning once per node. It's kept in `.chat_cert/`
and reused until your IP addresses change. Voice is peer-to-peer without
STUN/TURN servers, so it works between devices on the same network. Each person
connects to every other person in the room, which suits small groups.
Use `--host 127.0.0.1` to keep it on this machine. Erlang distribution between
the nodes always stays on localhost, because the demo's cookie is hard-coded
and a reachable node with a known cookie lets anyone run code on it.
There are no accounts, so anyone on the network can join, and anyone can use `/crash` or `/halt`.

Code: `lib/demo/chat.ex`, `lib/demo/chat/*.ex`, `priv/static/index.html`.

## Try it by hand: a cluster in three terminals

```sh
# terminal 1
iex --name a@127.0.0.1 --cookie demo -S mix
# terminal 2
iex --name b@127.0.0.1 --cookie demo -S mix
# terminal 3
iex --name c@127.0.0.1 --cookie demo -S mix
```

Then, in **b**:

```elixir
Node.connect(:"a@127.0.0.1")   # c is connected automatically when it joins (mesh)
Node.list()

# Run code anywhere
Node.spawn(:"a@127.0.0.1", fn -> IO.puts("hi from #{node()}") end)
:erpc.call(:"c@127.0.0.1", System, :pid, [])

# A singleton reachable by name from every node
Demo.Counter.start()
Demo.Counter.incr()            # try this from a and c too
```

In **a**, watch for nodes going away:

```elixir
:net_kernel.monitor_nodes(true)
Process.monitor(:global.whereis_name(Demo.Counter))
# now press Ctrl+C twice in terminal b, then:
flush()
#=> {:nodedown, :"b@127.0.0.1"}
#=> {:DOWN, _, :process, _, :noconnection}
```

Run `:observer.start()` in any node to watch processes, supervision trees and
the whole cluster live (needs an Erlang build with wx support).

## Notes

- `epmd`, the Erlang port mapper, keeps running in the background after the demo.
  Run `epmd -kill` to stop it.
- Crash logs are switched off (`Logger.configure(level: :none)`) because the demo
  crashes things on purpose.
