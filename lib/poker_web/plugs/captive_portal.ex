defmodule PokerWeb.Plugs.CaptivePortal do
  import Plug.Conn

  # iOS envoie ses requêtes de détection vers captive.apple.com — notre DNS
  # les redirige vers le Pi, et ce plug répond avec le contenu attendu.
  # Sans ça, iOS attend les timeouts de ses requêtes Apple avant de laisser
  # l'utilisateur naviguer sur le réseau.

  @success_html "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"

  def init(opts), do: opts

  # iOS (ancien)
  def call(%Plug.Conn{request_path: "/hotspot-detect.html"} = conn, _) do
    conn |> put_resp_content_type("text/html") |> send_resp(200, @success_html) |> halt()
  end

  # iOS (récent, Host: www.apple.com)
  def call(%Plug.Conn{request_path: "/library/test/success.html"} = conn, _) do
    conn |> put_resp_content_type("text/html") |> send_resp(200, @success_html) |> halt()
  end

  # Android (attend un 204 vide)
  def call(%Plug.Conn{request_path: "/generate_204"} = conn, _) do
    conn |> send_resp(204, "") |> halt()
  end

  # Windows
  def call(%Plug.Conn{request_path: "/connecttest.txt"} = conn, _) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "Microsoft Connect Test")
    |> halt()
  end

  def call(conn, _), do: conn
end
