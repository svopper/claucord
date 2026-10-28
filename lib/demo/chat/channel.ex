defmodule Demo.Chat.Channel do
  @moduledoc """
  One process per channel for the whole cluster. It writes every message to
  Postgres, keeps the recent history in memory, and broadcasts new messages to
  everyone in the channel's `:pg` group.

  It is started lazily, under the local DynamicSupervisor of whichever node
  touches the channel first. If it crashes, or its node dies, the next start
  (by its supervisor, or by any node that uses the channel) reloads the
  history from the database, so nothing is lost.
  """
  use GenServer

  import Ecto.Query
  alias Demo.Repo
  alias Demo.Chat.Schema.Message

  @history 200

  # ── API ──────────────────────────────────────────────────────────────

  def group(channel), do: {:channel, channel}

  def history(channel), do: GenServer.call(ensure(channel), :history)
  def post(channel, msg), do: GenServer.call(ensure(channel), {:post, msg})
  def crash(channel), do: GenServer.cast(ensure(channel), :boom)

  @doc "Adds a system message and makes every client reload the channel."
  def announce_reset(channel, text), do: GenServer.call(ensure(channel), {:reset, text})

  def whereis(channel), do: :global.whereis_name({__MODULE__, channel})

  @doc "Returns the channel's pid, starting it on this node if nobody runs it."
  def ensure(channel) do
    case whereis(channel) do
      :undefined ->
        case DynamicSupervisor.start_child(Demo.Chat.ChannelSup, {__MODULE__, channel}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  def start_link(channel), do: start_link(channel, 20)

  # When we are restarted after a crash, :global may not have noticed the old
  # process is gone yet. Give it a moment instead of failing the restart.
  defp start_link(channel, retries) do
    case GenServer.start_link(__MODULE__, channel, name: {:global, {__MODULE__, channel}}) do
      {:error, {:already_started, pid}} when node(pid) == node() and retries > 0 ->
        Process.sleep(10)
        start_link(channel, retries - 1)

      other ->
        other
    end
  end

  # ── Server ───────────────────────────────────────────────────────────

  @impl true
  def init(channel) do
    rows =
      Repo.all(
        from(m in Message, where: m.channel == ^channel, order_by: [desc: m.id], limit: @history)
      )

    # Newest first, like `store/2` keeps them.
    {:ok, %{channel: channel, messages: Enum.map(rows, &to_event/1)}}
  end

  @impl true
  def handle_call(:history, _from, s), do: {:reply, history_event(s), s}

  def handle_call({:post, msg}, _from, s) do
    {msg, s} = store(msg, s)
    broadcast(s.channel, %{type: "message", message: msg})
    {:reply, :ok, s}
  end

  def handle_call({:reset, text}, _from, s) do
    {_msg, s} = store(%{system: true, text: text}, s)
    broadcast(s.channel, history_event(s))
    {:reply, :ok, s}
  end

  @impl true
  def handle_cast(:boom, _s), do: raise("channel process crashed on purpose")

  # Written to Postgres before anyone sees it.
  defp store(msg, s) do
    row =
      Repo.insert!(%Message{
        channel: s.channel,
        user_name: msg[:user],
        color: msg[:color],
        node: msg[:node] && to_string(msg[:node]),
        text: msg[:text] || "",
        gif: msg[:gif],
        system: Map.get(msg, :system, false)
      })

    msg = to_event(row)
    {msg, %{s | messages: Enum.take([msg | s.messages], @history)}}
  end

  defp to_event(%Message{} = m) do
    %{
      id: m.id,
      channel: m.channel,
      host: node(),
      ts: DateTime.to_unix(m.inserted_at, :millisecond),
      user: m.user_name,
      color: m.color,
      node: m.node,
      text: m.text,
      gif: m.gif,
      system: m.system
    }
  end

  defp history_event(s) do
    %{
      type: "history",
      channel: s.channel,
      host: node(),
      pid: inspect(self()),
      messages: Enum.reverse(s.messages)
    }
  end

  defp broadcast(channel, event) do
    for pid <- :pg.get_members(group(channel)), do: send(pid, {:chat_event, event})
  end
end
