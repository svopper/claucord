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

    conn
    |> WebSockAdapter.upgrade(Demo.Chat.Socket, %{name: conn.query_params["name"]},
      timeout: :infinity
    )
    |> halt()
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
end
