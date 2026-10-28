# BEAM Chat

A real-time chat with a Discord-style layout, built on Elixir and OTP and served by
every node in a cluster. Text channels, GIFs, and voice, video and screen sharing.
Messages and created channels are stored in Postgres, which runs in Docker.

You need Elixir ≥ 1.18 / OTP ≥ 25 (`brew install elixir`) and Docker.

```sh
docker compose up -d      # Postgres 18 on 127.0.0.1:5433 (data kept in a Docker volume)
mix chat --nodes 3        # chat4000, chat4001, chat4002 on :4000, :4001, :4002
```

Open http://localhost:4000 and http://localhost:4001 in two windows, using different names.
The users are connected to different VMs but chat together.

## What's in it

| In the UI | What's behind it |
|-----------|------------------|
| **Server rail** (left): one icon per cluster node, with its user count. Click one to move your connection to that node. | Each node joins a `{:chat_node, http_port, https_port}` `:pg` group |
| **Channels**: messages and history, plus unread badges | One `Demo.Chat.Channel` GenServer per channel for the *whole cluster*, registered in `:global`, started lazily on the first node that needs it. The header pill shows which node runs it. |
| **Members** (right), grouped by node | Presence is just `:pg` membership, pushed live via `:pg.monitor_scope/0`. No heartbeats and no cleanup code. |
| **Typing indicator**, @mentions, `code` and **bold** formatting | Plain Erlang messages to the channel's `:pg` group |
| `/crash` | Crashes the channel process. Its supervisor restarts it and the new process reloads the history from Postgres. Everyone's connection survives. |
| `/halt` | Shuts down the node you're connected to. Its users disappear from presence, and your browser fails over to another node. |
| `/where` | Shows the pid and node of the channel process |
| **Create channels**: the **+** next to "Text channels" or "Voice channels" | The channel list is replicated on every node (`Demo.Chat.Directory`). A new channel is sent to every node, and copies are merged as a set union (a grow-only set, a simple CRDT), so there's no central owner. Channels survive losing the node they were created on, and nodes swap full lists when they connect, so newcomers catch up. |
| **GIF picker** (the GIF button in the message box) | Search goes through the server (`GET /gifs?q=`), so the GIPHY key never reaches browsers. Each node caches results in ETS for 10 minutes. GIF messages are only accepted from GIPHY's media domain. |
| **Voice channels** (Lounge, Stand-up), with speaking rings, mute, deafen, join/leave chimes, **video** and **screen sharing** (camera and screen buttons in the voice bar) | Audio goes browser-to-browser over WebRTC. The cluster is the signaling server: who is in a room is a `:pg` group, and offers, answers and ICE candidates are routed to the other person's socket process, whichever node it's on. If your node dies mid-call, your browser fails over and rejoins the room. |

Code: `lib/demo/chat.ex`, `lib/demo/chat/*.ex`, `priv/static/index.html`.

## Running nodes

`mix chat --nodes N` starts this VM plus N−1 peer VMs. You can also run nodes in
separate terminals:

```sh
mix chat                          # terminal 1 → :4000
mix chat --port 4001 --join 4000  # terminal 2 → :4001
```

To run one chat across separate machines, even on different networks, see
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md). It covers the private network,
HTTPS, Postgres, TURN for voice, and all the settings (`mix help chat` lists them too).

## Database

`mix chat` creates and updates the tables itself. To use another database, set
`DATABASE_URL`, e.g. `DATABASE_URL=ecto://user:pass@host:5432/db mix chat`. Each
node keeps 2 connections, and the container allows 500.

What's stored: messages, GIFs, system messages and created channels. A channel's
process loads its recent history when it starts, so a crash, a dead node or a full
restart of every node loses nothing. Presence, voice and video are live state, so
they aren't stored.

`docker compose down` stops Postgres and keeps the data; add `-v` to delete it.

## GIFs

GIF search uses [GIPHY](https://developers.giphy.com/) (Google shut down the
Tenor API in June 2026). Get a free API key there and start the chat with it:

```sh
GIPHY_API_KEY=your-key mix chat --nodes 3
```

Without a key, everything else works and the picker explains how to get one.

## Other devices, HTTPS and voice

The web UI listens on all interfaces, so phones and laptops on your network can
join through the LAN addresses `mix chat` prints, e.g. `https://192.168.1.20:4443`.
Use `--host 127.0.0.1` to keep it on this machine.

Browsers only allow the microphone on `localhost` or over HTTPS, so every node
also serves HTTPS on its port + 443 (4443, 4444, …). The certificate is
self-signed: accept the browser warning once per node. It's kept in `.chat_cert/`
and reused until your IP addresses change.

Voice is peer-to-peer without STUN/TURN servers, so it works between devices on
the same network. Each person connects to every other person in the room, which
suits small groups. Video is capped per stream: cameras at 500 kbps, screen
shares at 1.5 Mbps and 15 fps (tuned for sharp text). A 4-person call with
cameras on needs about 1.5 Mbps up and down per person, plus 1.5 Mbps for each
screen being shared.

## Voice over the internet (hosting from home)

Text chat works for anyone who can reach your forwarded port. Voice and video
are different: they go **directly between browsers**, and two browsers on
different home networks can't reach each other without help. A **TURN server**
on your machine relays the audio and video for them. Without one, calls fail,
and after 15 seconds the chat shows a notice saying so.

1. **Your friends must use HTTPS:** `https://<your-public-ip>:4443`. Browsers
   only allow the microphone over HTTPS. Accept the certificate warning once.
2. **Install coturn**, the TURN server: `brew install coturn` on macOS. On a
   Linux server you can use `docker compose --profile turn up -d` instead.
   Docker Desktop on macOS hides the real network addresses TURN needs, so use
   `bin/turn` there.
3. **Fill in `.env`:** `cp .env.example .env` and set the TURN secret
   (`openssl rand -hex 32`) and your public IP (your router's status page shows
   it) in all the places it asks for.
4. **Forward these ports** on your router to this machine:

   | Port | Protocol | For |
   |---|---|---|
   | 4443 | TCP | The chat over HTTPS (and 4444, 4445, … for the other nodes in the server rail) |
   | 3478 | UDP and TCP | TURN |
   | 49160–49200 | UDP | TURN relay traffic |

5. **Start both**, in two terminals:

   ```sh
   bin/turn
   set -a; . ./.env; set +a; mix chat --nodes 4
   ```

   `mix chat` warns at startup if it's reachable but has no TURN server.

The TURN server only gives logins to browsers connected to your chat (they
expire after 12 hours), and it can't be used to reach other devices on your
home network. If your public IP changes, update `.env` and restart both. On
macOS, allow `turnserver` if the firewall asks. While the chat is on the
internet, consider setting `CHAT_INVITE_CODE` and `CHAT_DEMO_COMMANDS=false`.

## Security notes

- There are no accounts, so anyone who can reach the chat can join, and anyone
  can use `/crash` or `/halt`. For deployments, set `CHAT_INVITE_CODE` and
  `CHAT_DEMO_COMMANDS=false`.
- On one machine, node-to-node traffic stays on localhost with a built-in
  cookie. A node reachable from other machines refuses to start without a
  secret `CHAT_COOKIE`, because anyone who knows the cookie can run code on it.
- WebSocket connections are only accepted from pages served by the cluster
  (checked with the `Origin` header).

## Notes

- `epmd`, the Erlang port mapper, keeps running in the background after you stop
  the chat. Run `epmd -kill` to stop it.
- Run `:observer.start()` from `iex --name x@127.0.0.1 --cookie elixir_demo_cookie`
  and connect to a chat node to watch processes, supervision trees and the cluster
  live (needs an Erlang build with wx support).
