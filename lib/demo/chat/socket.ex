defmodule Demo.Chat.Socket do
  @moduledoc "One process per connected browser tab."
  @behaviour WebSock

  alias Demo.Chat.{Channel, Directory, Presence}

  @colors ~w(#f47b67 #f8a532 #48b784 #45ddc0 #5865f2 #9b84ec #eb459e #3ba5f0)

  @impl true
  def init(%{name: name}) do
    name = clean_name(name)
    color = Enum.at(@colors, :erlang.phash2(name, length(@colors)))

    # A random id that other browsers use to address us for voice signaling.
    id = Base.url_encode64(:crypto.strong_rand_bytes(9))

    :ok = :pg.join({:presence, name, color}, self())
    :ok = :pg.join({:peer, id}, self())
    :ok = :pg.join(Presence.subscriber_group(), self())
    # Subscribe to every channel so the client can show unread badges.
    text_channels = Directory.text_names()
    for c <- text_channels, do: :ok = :pg.join(Channel.group(c), self())

    welcome =
      Presence.snapshot()
      |> Map.merge(%{
        type: "welcome",
        you: %{id: id, name: name, color: color, node: node()},
        channels: Directory.text_channels(),
        voice_rooms: Directory.voice_rooms()
      })

    state = %{
      id: id,
      name: name,
      color: color,
      channel: "general",
      voice: nil,
      muted: false,
      video: false,
      subscribed: MapSet.new(text_channels)
    }

    {:push, {:text, JSON.encode!(welcome)}, state}
  end

  @impl true
  def handle_in({text, opcode: :text}, state) do
    case JSON.decode(text) do
      {:ok, msg} -> handle_client(msg, state)
      _ -> {:ok, state}
    end
  end

  @impl true
  # The channel list changed somewhere in the cluster: subscribe to new text
  # channels (for unread badges) before telling the browser.
  def handle_info({:chat_event, %{type: "channels"} = event}, state) do
    push(event, subscribe(state, Enum.map(event.channels, & &1.name)))
  end

  def handle_info({:chat_event, event}, state), do: push(event, state)
  def handle_info(_other, state), do: {:ok, state}

  # ── Client messages ──────────────────────────────────────────────────

  defp handle_client(%{"type" => "join", "channel" => c}, state) do
    if c in Directory.text_names() do
      push(Channel.history(c), %{state | channel: c})
    else
      {:ok, state}
    end
  end

  defp handle_client(%{"type" => "typing"}, state) do
    event = %{type: "typing", user: state.name, channel: state.channel}

    for pid <- :pg.get_members(Channel.group(state.channel)), pid != self() do
      send(pid, {:chat_event, event})
    end

    {:ok, state}
  end

  defp handle_client(%{"type" => "message", "gif" => gif}, state) do
    case Demo.Chat.Gifs.clean(gif) do
      {:ok, gif} ->
        Channel.post(state.channel, %{
          user: state.name,
          color: state.color,
          node: node(),
          text: "",
          gif: gif
        })

        {:ok, state}

      :error ->
        {:ok, state}
    end
  end

  defp handle_client(%{"type" => "message", "text" => text}, state) when is_binary(text) do
    case String.trim(text) do
      "" -> {:ok, state}
      "/" <> command -> command(String.downcase(command), state)
      text -> post(String.slice(text, 0, 2000), state)
    end
  end

  # ── Voice ──────────────────────────────────────────────────────────
  #
  # Audio flows browser-to-browser over WebRTC. The cluster only does what
  # it is good at: knowing who is in which room (a :pg group, so presence
  # handles it) and routing signaling messages to a socket process on any node.

  defp handle_client(%{"type" => "voice_join", "room" => room}, state) do
    if room in Directory.voice_names() do
      state = %{leave_voice(state) | voice: room}
      :ok = :pg.join(voice_group(state), self())
      {:ok, state}
    else
      {:ok, state}
    end
  end

  defp handle_client(%{"type" => "voice_leave"}, state), do: {:ok, leave_voice(state)}

  # Mic and camera on/off. Both are part of the :pg group key, so presence
  # tells everyone about the change.
  defp handle_client(%{"type" => "voice_state", "muted" => muted, "video" => video}, state)
       when is_boolean(muted) and is_boolean(video) do
    case state do
      %{voice: nil} ->
        {:ok, %{state | muted: muted, video: video}}

      %{voice: room} ->
        state = %{leave_voice(state) | voice: room, muted: muted, video: video}
        :ok = :pg.join(voice_group(state), self())
        {:ok, state}
    end
  end

  # An SDP offer/answer or ICE candidate for another browser, wherever it is.
  defp handle_client(%{"type" => "signal", "to" => to, "data" => data}, %{voice: room} = state)
       when is_binary(to) and is_map(data) and room != nil do
    for pid <- :pg.get_members({:peer, to}) do
      send(pid, {:chat_event, %{type: "signal", from: state.id, data: data}})
    end

    {:ok, state}
  end

  defp handle_client(%{"type" => "create_channel", "kind" => kind, "name" => name} = msg, state)
       when is_binary(kind) and is_binary(name) do
    topic = if is_binary(msg["topic"]), do: msg["topic"], else: ""

    case Directory.create(kind, name, topic, state.name) do
      {:ok, channel} ->
        state = if kind == "text", do: subscribe(state, [channel.name]), else: state

        if kind == "text" do
          Channel.post(channel.name, %{
            system: true,
            text:
              "📣 #{state.name} created ##{channel.name} from #{node()}. Every node has it now."
          })
        end

        push(%{type: "channel_created", kind: kind, channel: channel}, state)

      {:error, reason} ->
        push(%{type: "create_error", text: reason}, state)
    end
  end

  defp handle_client(_unknown, state), do: {:ok, state}

  defp subscribe(state, names) do
    new = for name <- names, not MapSet.member?(state.subscribed, name), do: name
    for name <- new, do: :ok = :pg.join(Channel.group(name), self())
    %{state | subscribed: MapSet.union(state.subscribed, MapSet.new(new))}
  end

  defp voice_group(s), do: {:voice, s.voice, s.id, s.name, s.color, s.muted, s.video}

  defp leave_voice(%{voice: nil} = state), do: state

  defp leave_voice(state) do
    :pg.leave(voice_group(state), self())
    %{state | voice: nil}
  end

  # ── Slash commands ───────────────────────────────────────────────────

  defp command("help", state) do
    notice(
      """
      /crash: crash this channel's process; its supervisor restarts it
      /halt: shut down the node you're connected to; you fail over to another one
      /where: show where this channel's process runs
      """,
      state
    )
  end

  defp command("where", state) do
    pid = Channel.ensure(state.channel)
    notice("##{state.channel} is #{inspect(pid)} on #{node(pid)}. You are on #{node()}.", state)
  end

  defp command("crash", state) do
    c = state.channel
    old = Channel.ensure(c)
    Channel.crash(c)
    new = await_restart(c, old)

    Channel.announce_reset(
      c,
      "💥 #{state.name} crashed ##{c} (#{inspect(old)} on #{node(old)}). " <>
        "Its supervisor restarted it as #{inspect(new)}, which reloaded the history from Postgres. " <>
        "Nobody's connection noticed."
    )

    {:ok, state}
  end

  defp command("halt", state) do
    if Application.get_env(:demo, :chat_primary, false) do
      notice(
        "This is the primary node that started the cluster, so connect to another node first.",
        state
      )
    else
      post_system(
        "🔌 #{state.name} pulled the plug on #{node()}. Everyone on it fails over.",
        state
      )

      spawn(fn ->
        Process.sleep(300)
        System.halt()
      end)

      {:ok, state}
    end
  end

  defp command(other, state), do: notice("Unknown command /#{other}. Try /help.", state)

  # ── Helpers ──────────────────────────────────────────────────────────

  defp post(text, state) do
    Channel.post(state.channel, %{user: state.name, color: state.color, node: node(), text: text})
    {:ok, state}
  end

  defp post_system(text, state) do
    Channel.post(state.channel, %{system: true, text: text})
    {:ok, state}
  end

  defp notice(text, state), do: push(%{type: "notice", text: String.trim(text)}, state)

  defp push(event, state), do: {:push, {:text, JSON.encode!(event)}, state}

  defp await_restart(channel, old, tries \\ 100) do
    case Channel.whereis(channel) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ when tries > 0 ->
        Process.sleep(10)
        await_restart(channel, old, tries - 1)

      _ ->
        Channel.ensure(channel)
    end
  end

  defp clean_name(name) when is_binary(name) do
    case name |> String.trim() |> String.slice(0, 24) do
      "" -> clean_name(nil)
      name -> name
    end
  end

  defp clean_name(_), do: "guest-#{:rand.uniform(9999)}"
end
