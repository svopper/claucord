defmodule Demo.Chat.Presence do
  @moduledoc """
  Who is online, and on which node, derived purely from `:pg` groups:

    * every WebSocket process joins `{:presence, name, color}`
    * every chat node's Presence process joins `{:chat_node, http_port, https_port}`
    * every voice participant joins `{:voice, room, id, name, color, muted?, camera?, screen?}`

  `:pg` removes members automatically when their process or node dies, and
  `:pg.monitor_scope/1` tells us about every change, so presence is always
  correct without any heartbeats or cleanup code.
  """
  use GenServer

  def start_link(ports), do: GenServer.start_link(__MODULE__, ports, name: __MODULE__)

  @doc "Local WebSocket processes that receive presence updates."
  def subscriber_group, do: :chat_sockets

  def snapshot do
    groups = :pg.which_groups()

    nodes =
      for {:chat_node, port, https_port} = g <- groups, pid <- :pg.get_members(g) do
        %{name: node(pid), port: port, https_port: https_port}
      end
      |> Enum.sort_by(& &1.port)

    users =
      for {:presence, name, color} = g <- groups, pid <- :pg.get_members(g) do
        %{name: name, color: color, node: node(pid)}
      end
      |> Enum.uniq()
      |> Enum.sort_by(&String.downcase(&1.name))

    voice =
      for {:voice, room, id, name, color, muted, video, screen} = g <- groups,
          pid <- :pg.get_members(g) do
        %{
          room: room,
          id: id,
          name: name,
          color: color,
          muted: muted,
          video: video,
          screen: screen,
          node: node(pid)
        }
      end
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&String.downcase(&1.name))

    %{nodes: nodes, users: users, voice: voice}
  end

  @impl true
  def init({port, https_port}) do
    :ok = :pg.join({:chat_node, port, https_port}, self())
    {ref, _groups} = :pg.monitor_scope()
    :ok = :net_kernel.monitor_nodes(true)
    {:ok, %{ref: ref, timer: nil}}
  end

  @impl true
  def handle_info({ref, _join_or_leave, _group, _pids}, %{ref: ref} = s), do: schedule(s)
  def handle_info({:nodeup, _}, s), do: schedule(s)
  def handle_info({:nodedown, _}, s), do: schedule(s)

  def handle_info(:push, s) do
    event = Map.put(snapshot(), :type, "presence")
    for pid <- :pg.get_local_members(subscriber_group()), do: send(pid, {:chat_event, event})
    {:noreply, %{s | timer: nil}}
  end

  # Many joins/leaves can arrive at once (a node with 50 users going down);
  # coalesce them into a single push.
  defp schedule(%{timer: nil} = s),
    do: {:noreply, %{s | timer: Process.send_after(self(), :push, 50)}}

  defp schedule(s), do: {:noreply, s}
end
