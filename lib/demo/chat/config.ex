defmodule Demo.Chat.Config do
  @moduledoc """
  Deployment settings, read from environment variables so that peer nodes
  (which inherit the environment) see the same values. See
  `docs/DEPLOYMENT.md`.

    * `CHAT_DEMO_COMMANDS` - `false` turns off `/crash` and `/halt`
    * `CHAT_INVITE_CODE` - if set, browsers must send it before joining
    * `CHAT_STUN_URLS` - comma-separated, e.g. `stun:turn.example.com:3478`
    * `CHAT_TURN_URLS` - comma-separated, e.g. `turn:turn.example.com:3478`
    * `CHAT_TURN_SECRET` - coturn's `static-auth-secret`
  """

  # How long a TURN login handed to a browser stays valid.
  @turn_ttl_seconds 12 * 60 * 60

  def demo_commands?, do: System.get_env("CHAT_DEMO_COMMANDS", "true") not in ~w(false 0 no off)

  def invite_code, do: env("CHAT_INVITE_CODE")

  def invite_ok?(given) do
    case invite_code() do
      nil -> true
      code -> is_binary(given) and Plug.Crypto.secure_compare(given, code)
    end
  end

  @doc """
  The `iceServers` list for `RTCPeerConnection`. TURN logins use coturn's
  shared-secret scheme: the username is `<expiry>:<user>` and the password is
  base64(HMAC-SHA1(secret, username)), so the secret never leaves the server.
  """
  def ice_servers(user) do
    stun = list("CHAT_STUN_URLS")
    turn = list("CHAT_TURN_URLS")

    stun_servers = if stun == [], do: [], else: [%{urls: stun}]

    turn_servers =
      case {turn, env("CHAT_TURN_SECRET")} do
        {[], _} ->
          []

        {_, nil} ->
          []

        {urls, secret} ->
          username = "#{System.os_time(:second) + @turn_ttl_seconds}:#{user}"
          credential = :crypto.mac(:hmac, :sha, secret, username) |> Base.encode64()
          [%{urls: urls, username: username, credential: credential}]
      end

    stun_servers ++ turn_servers
  end

  @doc "Problems worth refusing to start over."
  def problems do
    if list("CHAT_TURN_URLS") != [] and env("CHAT_TURN_SECRET") == nil,
      do: ["CHAT_TURN_URLS is set but CHAT_TURN_SECRET isn't, so TURN can't be used."],
      else: []
  end

  defp list(var) do
    (env(var) || "") |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  defp env(var) do
    case System.get_env(var) do
      value when value in [nil, ""] -> nil
      value -> value
    end
  end
end
