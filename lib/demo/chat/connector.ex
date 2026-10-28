defmodule Demo.Chat.Connector do
  @moduledoc """
  Keeps this node connected to the nodes given with `--join` / `CHAT_JOIN`.

  It retries every few seconds, so nodes can start in any order, and it
  reconnects after a node restarts or the network between machines drops.
  Connecting to one node is enough: Erlang then connects us to the rest.
  """
  use GenServer
  require Logger

  @every :timer.seconds(5)

  def start_link(targets), do: GenServer.start_link(__MODULE__, targets, name: __MODULE__)

  @impl true
  def init(targets) do
    send(self(), :connect)
    # `up` is nil until the first attempt, so that one always reports.
    {:ok, %{targets: MapSet.new(targets) |> MapSet.delete(node()), up: nil}}
  end

  @impl true
  def handle_info(:connect, %{targets: targets, up: before} = s) do
    up = for t <- targets, t in Node.list() or Node.connect(t), into: MapSet.new(), do: t
    was_up = before || MapSet.new()

    for t <- MapSet.difference(up, was_up), do: Logger.warning("connected to #{t}")

    for t <- MapSet.difference(targets, up), before == nil or t in was_up do
      Logger.warning("can't reach #{t}; retrying every #{div(@every, 1000)}s")
    end

    Process.send_after(self(), :connect, @every)
    {:noreply, %{s | up: up}}
  end
end
