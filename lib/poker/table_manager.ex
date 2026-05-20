defmodule Poker.TableManager do

  # ---------------------------------------------------------------------------
  # Struct : Table
  # État complet d'une table de jeu. Vit uniquement en mémoire (GenServer).
  # Pas de persistance — c'est éphémère, une session de soirée.
  # ---------------------------------------------------------------------------
  defmodule Table do
    @moduledoc """
    État global de la table. Géré par le GenServer Poker.TableManager.

    Cycle de vie :
      :waiting  → les joueurs scannent leur tag et rejoignent
      :playing  → une partie est en cours, `hand` est non-nil
    """

    @max_players 6
    @initial_stack 1000  # Valeur par défaut si le joueur n'a pas de bankroll en base

    defstruct [
      :table_id,         # String UUID — identifiant unique de la table
      :gm_id,            # String — tag NFC du joueur ayant le rôle GM
      players: [],       # [%Player{}] dans l'ordre de scan (= ordre des seats)
      status: :waiting,  # :waiting | :playing
      hand: nil,         # %Hand{} | nil
      dealer_seat: 0     # Integer — index dans `players` du dealer actuel
    ]

    def max_players, do: @max_players
    def initial_stack, do: @initial_stack
  end

  # ---------------------------------------------------------------------------
  # Struct : Player
  #
  # Le `id` est le string brut envoyé par l'iPhone via NFC.
  # C'est aussi la clé primaire dans la table SQLite `players`.
  #
  # Schéma SQLite attendu :
  #   CREATE TABLE players (
  #     id      TEXT PRIMARY KEY,   -- tag NFC string
  #     name    TEXT NOT NULL,
  #     bankroll INTEGER NOT NULL DEFAULT 1000
  #   );
  #
  # Le `stack` ici EST la bankroll : toute action de jeu (blind, mise, gain)
  # doit déclencher un UPDATE players SET bankroll = ? WHERE id = ?
  # ---------------------------------------------------------------------------
  defmodule Player do
    @moduledoc """
    Représente un joueur à la table.

    `stack` est synchronisé en temps réel avec `bankroll` dans SQLite.
    La source de vérité en cours de partie est le GenServer ;
    SQLite est mis à jour à chaque changement de stack via Poker.Repo.

    Transitions de `status` :
      :active  → joue normalement
      :folded  → s'est couché sur la main en cours (redevient :active à la prochaine)
      :all_in  → a misé tout son stack, ne peut plus agir
      :out     → éliminé (stack == 0), ne participe plus aux mains
    """

    defstruct [
      :id,               # String — tag NFC, clé primaire SQLite
      :name,             # String — pseudo (lu depuis SQLite à la connexion)
      :stack,            # Integer — bankroll en cours (= SQLite players.bankroll)
      :seat,             # Integer 0..5 — position à la table, attribué à l'arrivée
      status: :active    # :active | :folded | :all_in | :out
    ]
  end

  # ---------------------------------------------------------------------------
  # Struct : Hand
  # Une main de poker. Créée à chaque "Nouvelle main", détruite après l'abattage.
  # Pas de persistance — les résultats sont répercutés sur Player.stack (→ SQLite).
  # ---------------------------------------------------------------------------
  defmodule Hand do
    @moduledoc """
    État d'une main en cours.

    `bets` : mises du TOUR ACTUEL (remises à zéro à chaque nouveau round).
    `total_bets` : cumul des mises depuis le début de la main (pour calcul side pots).

    Progression de `current_round` :
      :preflop → :flop → :turn → :river → :showdown

    `side_pots` : liste de {montant, [player_ids éligibles]}.
    Calculés automatiquement quand un joueur passe :all_in.
    Nil ou [] si pas de all-in en cours.
    """

    defstruct [
      :pot,                     # Integer — pot principal cumulé
      :side_pots,               # [{amount :: integer, eligible :: [String.t()]}] | []
      :current_round,           # :preflop | :flop | :turn | :river | :showdown
      :current_player_seat,     # Integer — index dans Table.players du joueur à agir
      :last_raise,              # Integer | nil — montant de la dernière relance
      :bets,                    # %{player_id => integer} mises du tour en cours
      :total_bets,              # %{player_id => integer} mises totales de la main
      :community_cards_count    # Integer : 0 (preflop) | 3 (flop) | 4 (turn) | 5 (river)
    ]
  end


  # ------------------GenServer-------------------------
  #
  #
  #
  # ----------------------------------------------------
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, %Table{}, opts)
  end

  def create_table(gm_id) do
    
  end

  # --------------------CallBack---------------------------
  #
  #
  #
  # --------------------------------------------------------

  def init(state) do
    {:ok, state}
  end

end
