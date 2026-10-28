defmodule Demo.Chat.Gifs do
  @moduledoc """
  GIF search through GIPHY, proxied by the server so the API key (from the
  `GIPHY_API_KEY` environment variable) never reaches browsers.

  Results are cached per node in ETS for a few minutes: the picker searches
  as you type and GIPHY's free keys are rate limited.
  """
  use GenServer

  @ttl :timer.minutes(10)
  @max_cached 500
  @media ~r{\Ahttps://media\d*\.giphy\.com/}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(__MODULE__, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  def configured?, do: api_key() != nil

  @doc "Trending GIFs for an empty query, search results otherwise."
  def search(query) do
    query = query |> to_string() |> String.trim() |> String.slice(0, 50)
    key = String.downcase(query)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(__MODULE__, key) do
      [{^key, at, gifs}] when now - at < @ttl ->
        {:ok, gifs}

      _ ->
        with {:ok, gifs} <- fetch(query) do
          if :ets.info(__MODULE__, :size) >= @max_cached, do: :ets.delete_all_objects(__MODULE__)
          :ets.insert(__MODULE__, {key, now, gifs})
          {:ok, gifs}
        end
    end
  end

  @doc "Validates a GIF sent by a browser before it goes into a channel."
  def clean(%{"url" => url, "width" => w, "height" => h} = gif)
      when is_binary(url) and is_integer(w) and is_integer(h) and w in 1..2000 and h in 1..2000 do
    if Regex.match?(@media, url) and byte_size(url) < 1000 do
      {:ok,
       %{
         url: url,
         width: w,
         height: h,
         title: gif |> Map.get("title", "") |> to_string() |> String.slice(0, 140)
       }}
    else
      :error
    end
  end

  def clean(_), do: :error

  defp fetch(query) do
    case api_key() do
      nil ->
        {:error, :no_key}

      key ->
        {endpoint, params} = if query == "", do: {"trending", []}, else: {"search", [q: query]}
        params = URI.encode_query([api_key: key, limit: 24, rating: "pg-13"] ++ params)
        url = ~c"https://api.giphy.com/v1/gifs/#{endpoint}?#{params}"

        ssl = [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]

        case :httpc.request(:get, {url, []}, [ssl: ssl, timeout: 8_000], body_format: :binary) do
          {:ok, {{_, 200, _}, _headers, body}} -> {:ok, parse(JSON.decode!(body))}
          {:ok, {{_, status, _}, _headers, _body}} -> {:error, {:giphy_status, status}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc false
  # Turns a GIPHY search/trending response into what the picker needs.
  def parse(%{"data" => data}) do
    for %{"images" => %{"fixed_width" => full} = images} = gif <- data,
        is_binary(full["url"]) do
      small = images["fixed_width_small"] || full

      %{
        url: full["url"],
        preview: small["url"] || full["url"],
        width: to_int(full["width"]),
        height: to_int(full["height"]),
        title: gif["title"] || ""
      }
    end
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(s) when is_binary(s), do: String.to_integer(s)

  defp api_key do
    case System.get_env("GIPHY_API_KEY") do
      key when key in [nil, ""] -> nil
      key -> key
    end
  end
end
