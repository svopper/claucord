defmodule Demo.Chat.Router do
  @moduledoc false
  use Plug.Router

  plug :match
  plug :dispatch

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:demo, "priv/static/index.html"))
  end

  get "/ws" do
    conn = fetch_query_params(conn)

    if allowed_origin?(conn) do
      conn
      |> WebSockAdapter.upgrade(Demo.Chat.Socket, %{name: conn.query_params["name"]},
        timeout: :infinity
      )
      |> halt()
    else
      send_resp(conn, 403, "origin not allowed")
    end
  end

  # What the login screen needs to know before connecting.
  get "/config" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(%{invite_required: Demo.Chat.Config.invite_code() != nil}))
  end

  get "/gifs" do
    conn = fetch_query_params(conn)

    {status, body} =
      case Demo.Chat.Gifs.search(conn.query_params["q"] || "") do
        {:ok, gifs} -> {200, %{gifs: gifs}}
        {:error, :no_key} -> {503, %{error: "no_key"}}
        {:error, reason} -> {502, %{error: inspect(reason)}}
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # Browsers send an Origin header with every WebSocket request. Only pages
  # served by this cluster may connect: the same hostname as this request (any
  # port, which covers several nodes on one machine) or another node's public
  # URL. This stops other websites from opening a chat connection in a
  # visitor's browser. Requests without an Origin don't come from a browser.
  defp allowed_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        true

      [origin | _] ->
        uri = URI.parse(origin)
        # Only well-formed origins ("scheme://host[:port]", as browsers send them).
        well_formed? =
          uri.scheme != nil and uri.host != nil and
            URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port}) == origin

        well_formed? and (uri.host == conn.host or origin in Demo.Chat.Presence.public_urls())
    end
  end
end
