defmodule PokerWeb.NfcController do
  use PokerWeb, :controller

   alias Poker.Players.Registry


  @gm_tag_id System.get_env("GM_TAG_ID", "gm-master")
  # ---------------------------------------------------------------------------
  # GET /nfc/:tag_id
  # Point d'entrée unique pour tous les scans NFC
  # ---------------------------------------------------------------------------

  def handle(conn, %{"tag_id" => tag_id}) do
    case identify_tag(tag_id) do
      :gm -> handle_gm(conn, tag_id)
      :player -> handle_player(conn, tag_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Tag GM : déverrouille l'interface GM
  # -----

  defp handle_gm(conn, _tag_id) do
    # Redirige vers la LiveView GM avec un token de session
    conn
    |> put_session(:gm_unlocked, true)
    |> put_session(:gm_unlocked_at, System.system_time(:second))
    |> redirect(to: ~p"/gm")
  end

  # ---------------------------------------------------------------------------
  # Tag joueur connu : redirige vers sa vue
  # Tag joueur inconnu : propose l'enregistrement
  # ---------------------------------------------------------------------------


  defp handle_player(conn, tag_id) do
    case Registry.lookup(tag_id) do
      nil ->
        # Joueur inconnu → page d'enregistrement
        conn
        |> put_session(:pending_tag_id, tag_id)
        |> redirect(to: ~p"/players/new")

      player ->
        # Joueur connu → sa vue personnelle
        conn
        |> put_session(:current_tag_id, tag_id)
        |> redirect(to: ~p"/table")

    end

  end


  defp identify_tag(@gm_tag_id), do: :gm

  defp identify_tag(_tag_id), do: :player

end
