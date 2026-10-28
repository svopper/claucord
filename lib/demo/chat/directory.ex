defmodule Demo.Chat.Directory do
  @moduledoc """
  The list of text and voice channels, replicated on every chat node.

  There is no central owner: each node keeps a full copy, and a new channel is
  sent to every other node's Directory. Merging is a set union (a grow-only
  set, the simplest CRDT), so copies agree no matter in which order updates
  arrive, and the list survives losing any node. Directories swap their full
  lists whenever nodes connect, which also heals anything missed during a
  netsplit.

  Channels are keyed by `{kind, name}`. Created channels are also saved in
  Postgres, which is what makes them survive a full restart; its unique index
  decides if two nodes try to create the same channel at the same moment.
  """
  use GenServer

  alias Demo.Repo
  alias Demo.Chat.Schema.Channel, as: Row

  @group :chat_directory
  @max_per_kind 30

  # ── API ──────────────────────────────────────────────────────────────

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def text_channels, do: list(:text)
  def voice_rooms, do: list(:voice)
  def text_names, do: Enum.map(text_channels(), & &1.name)
  def voice_names, do: Enum.map(voice_rooms(), & &1.name)

  @doc "Creates a channel cluster-wide. `kind` is \"text\" or \"voice\"."
  def create(kind, name, topic, by) when kind in ["text", "voice"] do
    GenServer.call(__MODULE__, {:create, String.to_existing_atom(kind), name, topic, by})
  end

  def create(_kind, _name, _topic, _by), do: {:error, "Unknown channel type."}

  @doc "Lowercase letters, digits and dashes: \"My Room!\" -> \"my-room\"."
  def slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 24)
    |> String.trim("-")
  end

  defp list(kind), do: GenServer.call(__MODULE__, :all) |> list(kind)

  defp list(channels, kind) do
    channels
    |> Map.values()
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.sort_by(&{&1.at, &1.name})
    |> Enum.map(&public/1)
  end

  defp public(%{kind: :text} = c), do: %{name: c.name, topic: c.topic}
  defp public(%{kind: :voice} = c), do: %{name: c.name, title: c.title}

  # ── Server ───────────────────────────────────────────────────────────

  @impl true
  def init(nil) do
    :ok = :pg.join(@group, self())
    :ok = :net_kernel.monitor_nodes(true)
    # Ask whoever is already running for their list (and give them ours).
    send(self(), :exchange)
    {:ok, Map.merge(defaults(), saved())}
  end

  @impl true
  def handle_call(:all, _from, channels), do: {:reply, channels, channels}

  def handle_call({:create, kind, raw_name, topic, by}, _from, channels) do
    name = slug(to_string(raw_name))
    title = raw_name |> to_string() |> String.trim() |> String.slice(0, 24)

    cond do
      name == "" ->
        {:reply, {:error, "Use at least one letter or digit in the name."}, channels}

      Map.has_key?(channels, {kind, name}) ->
        {:reply, {:error, "There's already a #{kind} channel called #{name}."}, channels}

      Enum.count(channels, fn {{k, _}, _} -> k == kind end) >= @max_per_kind ->
        {:reply, {:error, "That's the maximum of #{@max_per_kind} #{kind} channels."}, channels}

      true ->
        row = %Row{
          kind: to_string(kind),
          name: name,
          title: if(title == "", do: name, else: title),
          topic: topic |> to_string() |> String.trim() |> String.slice(0, 120),
          created_by: by,
          created_on: to_string(node())
        }

        case Repo.insert(row, on_conflict: :nothing, conflict_target: [:kind, :name]) do
          {:ok, %Row{id: id} = row} when id != nil ->
            entry = to_entry(row)
            channels = Map.put(channels, {kind, name}, entry)
            for pid <- others(), do: send(pid, {:merge, %{{kind, name} => entry}, nil})
            notify_sockets(channels)
            {:reply, {:ok, public(entry)}, channels}

          # Another node created it a moment ago; it will reach us shortly.
          {:ok, _not_inserted} ->
            {:reply, {:error, "There's already a #{kind} channel called #{name}."}, channels}
        end
    end
  end

  defp saved do
    for row <- Repo.all(Row), into: %{} do
      entry = to_entry(row)
      {{entry.kind, entry.name}, entry}
    end
  end

  defp to_entry(%Row{} = row) do
    %{
      kind: String.to_existing_atom(row.kind),
      name: row.name,
      title: row.title,
      topic: row.topic,
      by: row.created_by,
      at: DateTime.to_unix(row.inserted_at, :millisecond),
      node: row.created_on
    }
  end

  @impl true
  def handle_info({:merge, incoming, reply_to}, channels) do
    merged = merge(channels, incoming)
    if reply_to, do: send(reply_to, {:merge, merged, nil})
    if merged != channels, do: notify_sockets(merged)
    {:noreply, merged}
  end

  # A node joined: swap full lists with every other directory. :pg needs a
  # moment to learn about the new node's members, hence the short delay.
  def handle_info({:nodeup, _node}, channels) do
    Process.send_after(self(), :exchange, 500)
    {:noreply, channels}
  end

  def handle_info({:nodedown, _node}, channels), do: {:noreply, channels}

  def handle_info(:exchange, channels) do
    for pid <- others(), do: send(pid, {:merge, channels, self()})
    {:noreply, channels}
  end

  # Union of both sets; for the same key, the earliest creation wins.
  defp merge(ours, theirs) do
    Map.merge(ours, theirs, fn _key, a, b -> Enum.min_by([a, b], &{&1.at, &1.node}) end)
  end

  defp others, do: :pg.get_members(@group) -- [self()]

  # Tell this node's browsers about the new list.
  defp notify_sockets(channels) do
    event = %{
      type: "channels",
      channels: list(channels, :text),
      voice_rooms: list(channels, :voice)
    }

    for pid <- :pg.get_local_members(Demo.Chat.Presence.subscriber_group()) do
      send(pid, {:chat_event, event})
    end
  end

  defp defaults do
    # Built-in channels keep their listed order: `at` is their position,
    # which sorts before any real creation timestamp.
    text =
      for {{name, topic}, i} <- Enum.with_index(Demo.Chat.default_channels()) do
        {{:text, name},
         %{kind: :text, name: name, title: name, topic: topic, by: nil, at: i, node: nil}}
      end

    voice =
      for {{name, title}, i} <- Enum.with_index(Demo.Chat.default_voice_rooms()) do
        {{:voice, name},
         %{kind: :voice, name: name, title: title, topic: "", by: nil, at: i, node: nil}}
      end

    Map.new(text ++ voice)
  end
end
