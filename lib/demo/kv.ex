defmodule Demo.KV do
  @moduledoc "A tiny key/value GenServer that can be told to crash."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})
  def get(key), do: GenServer.call(__MODULE__, {:get, key})
  def crash!, do: GenServer.cast(__MODULE__, :boom)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:put, k, v}, _from, state), do: {:reply, :ok, Map.put(state, k, v)}
  def handle_call({:get, k}, _from, state), do: {:reply, Map.get(state, k), state}

  @impl true
  def handle_cast(:boom, _state), do: raise("💥 something went terribly wrong")
end

defmodule Demo.Clock do
  @moduledoc "An innocent bystander process that just counts ticks."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)
  def ticks, do: GenServer.call(__MODULE__, :ticks)

  @impl true
  def init(n) do
    :timer.send_interval(10, :tick)
    {:ok, n}
  end

  @impl true
  def handle_info(:tick, n), do: {:noreply, n + 1}

  @impl true
  def handle_call(:ticks, _from, n), do: {:reply, n, n}
end
