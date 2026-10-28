defmodule Demo.Chat.Cert do
  @moduledoc """
  A self-signed TLS certificate for the chat's HTTPS listener.

  Browsers only allow microphone access on `localhost` or over HTTPS, so voice
  chat from other devices needs HTTPS. The certificate is kept in `.chat_cert/`
  and only regenerated when the set of host names/IPs changes, so devices that
  accepted it once keep working across restarts.
  """

  @dir ".chat_cert"

  def ensure!(hosts) do
    dir = Path.expand(@dir)
    files = %{certfile: Path.join(dir, "cert.pem"), keyfile: Path.join(dir, "key.pem")}
    stamp = Path.join(dir, "hosts")
    wanted = hosts |> Enum.uniq() |> Enum.sort() |> Enum.join(",")

    unless File.exists?(files.certfile) and File.read(stamp) == {:ok, wanted} do
      File.mkdir_p!(dir)
      generate!(hosts, files)
      File.write!(stamp, wanted)
    end

    files
  end

  defp generate!(hosts, %{certfile: cert, keyfile: key}) do
    openssl =
      System.find_executable("openssl") ||
        raise "openssl is needed to create the HTTPS certificate"

    san =
      Enum.map_join(hosts, ",", fn host ->
        if match?({:ok, _}, :inet.parse_address(String.to_charlist(host))),
          do: "IP:#{host}",
          else: "DNS:#{host}"
      end)

    args =
      ~w(req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 825) ++
        ["-subj", "/CN=BEAM Chat (self-signed)", "-addext", "subjectAltName=#{san}"] ++
        ["-keyout", key, "-out", cert]

    case System.cmd(openssl, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> raise "could not create the HTTPS certificate:\n#{out}"
    end
  end
end
