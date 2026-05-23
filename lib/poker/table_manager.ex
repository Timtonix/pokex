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
    defstruct [
      :table_id,         # String UUID — identifiant unique de la table
      :gm_id,            # String — tag NFC du joueur ayant le rôle GM
      players: [],       # [%Player{}] dans l'ordre de scan (= ordre des seats)
      status: :waiting,  # :waiting | :playing
      hand: nil,         # %Hand{} | nil
      dealer_seat: 0     # Integer — index dans `players` du dealer actuel
    ]

    def max_players(), do:  6
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
  # Le `bankroll` ici EST la bankroll : toute action de jeu (blind, mise, gain)
  # doit déclencher un UPDATE players SET bankroll = ? WHERE id = ?
  # ---------------------------------------------------------------------------
  defmodule Player do
    @moduledoc """
    Représente un joueur à la table.

    `bankroll` est synchronisé en temps réel avec `bankroll` dans SQLite.
    La source de vérité en cours de partie est le GenServer ;
    SQLite est mis à jour à chaque changement de bankroll via Poker.Repo.

    Transitions de `status` :
      :active  → joue normalement
      :folded  → s'est couché sur la main en cours (redevient :active à la prochaine)
      :all_in  → a misé tout son bankroll, ne peut plus agir
      :out     → éliminé (bankroll == 0), ne participe plus aux mains
    """

    defstruct [
      :id,               # String — tag NFC, clé primaire SQLite
      :name,             # String — pseudo (lu depuis SQLite à la connexion)
      :bankroll,            # Integer — bankroll en cours (= SQLite players.bankroll)
      :seat,             # Integer 0..5 — position à la table, attribué à l'arrivée
      status: :active    # :active | :folded | :all_in | :out
    ]
  end

  # ---------------------------------------------------------------------------
  # Struct : Hand
  # Une main de poker. Créée à chaque "Nouvelle main", détruite après l'abattage.
  # Pas de persistance — les résultats sont répercutés sur Player.bankroll (→ SQLite).
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


  # ---------------------------------------------------------------------------
  # API publique — documentation des fonctions à implémenter
  # ---------------------------------------------------------------------------
  use GenServer
  alias Poker.TableManager
  alias Poker.Players.Registry




  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  @doc """
  crée une nouvelle table.

  Vérifie via `Registry.get_player/1` que le tag est connu et que `gm: true`.
  Le GM est automatiquement inscrit comme premier joueur (seat 0).

  ## Paramètres
  - `gm_tag` — String, tag NFC du GM (clé primaire SQLite)

  ## Retours
  - `{:ok, pid}` — table créée, GenServer démarré
  - `{:error, :not_found}` — tag inconnu dans Registry
  - `{:error, :not_gm}` — joueur trouvé mais `gm: false`

  ## Exemple
      iex> TableManager.create_table("TAG-GM-001")
      {:ok, %TableManager{...}}
  """
  @spec create_table(String.t()) :: {:ok, struct()} | {:error, :invalid_tag} | {:error, :already_existing}
  def create_table(gm_id) when is_binary(gm_id)do
    cond do
      String.trim(gm_id) == "" ->
        {:error, :invalid_tag}

      true ->
        GenServer.call(__MODULE__, {:create_table, gm_id})
    end
  end




  @doc """
  Ajoute un joueur à la table.

  La table doit être en statut `:waiting`.
  Vérifie via `Registry.get_player/1` que le tag est connu.
  Le joueur reçoit le prochain seat disponible (dans l'ordre d'appel).
  Le bankroll initial est lu depuis `bankroll` dans Registry.

  ## Paramètres
  - `tag_id` — String, tag NFC du joueur

  ## Retours
  - `{:ok, %Table{}}` — joueur ajouté, état complet retourné
  - `{:error, :not_found}` — tag inconnu dans Registry
  - `{:error, :game_already_started}` — la table est en `:playing`
  - `{:error, :player_already_registered}` — tag déjà présent dans `players`
  - `{:error, :table_full}` — 6 joueurs déjà inscrits

  ## Exemple
      iex> TableManager.join_table(pid, "TAG-P-002")
      {:ok, %Table{players: [%Player{id: "TAG-GM-001", seat: 0}, %Player{id: "TAG-P-002", seat: 1}], ...}}
  """
  def join_table(tag_id), do: GenServer.call(__MODULE__, {:join, tag_id})

  @spec get_state() :: any()
  @doc """
  Retourne l'état complet de la table.

  Utilisé par le LiveView pour s'abonner à l'état initial
  et reconstruire les assigns.

  ## Paramètres
  - `pid` — PID du GenServer

  ## Retours
  - `%Table{}` — toujours, pas d'erreur possible

  ## Exemple
      iex> TableManager.get_state(pid)
      %Table{status: :waiting, players: [...], hand: nil, ...}
  """
  def get_state(), do: GenServer.call(__MODULE__, :get_state)

  @doc """
  Démarre la partie.

  Seul le GM peut appeler cette fonction (vérifié via `caller_tag`).
  Nécessite au moins 2 joueurs en statut `:active`.
  Passe la table en `:playing`.
  Diffuse `{:table_updated, %Table{}}` à tous les abonnés PubSub.

  ## Paramètres
  - `pid` — PID du GenServer
  - `caller_tag` — String, tag NFC de l'appelant (doit être le GM)

  ## Retours
  - `{:ok, %Table{}}` — partie démarrée
  - `{:error, :not_gm}` — l'appelant n'est pas le GM
  - `{:error, :not_enough_players}` — moins de 2 joueurs
  - `{:error, :game_already_started}` — déjà en `:playing`

  ## Exemple
      iex> TableManager.start_game(pid, "TAG-GM-001")
      {:ok, %Table{status: :playing, ...}}
  """
  def start_game(caller_tag), do: GenServer.call(__MODULE__, {:start_game, caller_tag})

  @doc """
  Réinitialise la table à son état initial.

  Seul le GM peut appeler cette fonction.
  Remet `status: :waiting`, vide `players` et `hand`.
  Ne touche pas aux bankrolls (les bankrolls sont déjà synchronisés
  au fil de la partie via `Bankroll.update/2`).
  Diffuse `{:table_updated, %Table{}}` à tous les abonnés PubSub.

  ## Paramètres
  - `pid` — PID du GenServer
  - `caller_tag` — String, tag NFC de l'appelant (doit être le GM)

  ## Retours
  - `{:ok, %Table{}}` — table réinitialisée
  - `{:error, :not_gm}` — l'appelant n'est pas le GM

  ## Exemple
      iex> TableManager.reset_table(pid, "TAG-GM-001")
      {:ok, %Table{status: :waiting, players: [], hand: nil, ...}}
  """
  def reset_table(pid, caller_tag), do: GenServer.call(pid, {:reset_table, caller_tag})

  # ---------------------------------------------------------------------------
  # Fonctions privées utilitaires — à implémenter dans le module
  # ---------------------------------------------------------------------------

  # Vérifie que le tag appelant est bien le GM de cette table.
  # Utilisé dans les handle_call qui nécessitent les droits GM.
  #
  #   @spec is_gm?(String.t(), %Table{}) :: boolean()
  #   defp is_gm?(tag_id, table), do: table.gm_id == tag_id

  # Retourne le prochain seat disponible (longueur de la liste players).
  #
  #   @spec next_seat([%Player{}]) :: integer()
  #   defp next_seat(players), do: length(players)

  # Vérifie qu'un tag_id n'est pas déjà dans la liste players.
  #
  #   @spec already_registered?(String.t(), [%Player{}]) :: boolean()
  #   defp already_registered?(tag_id, players), do: Enum.any?(players, &(&1.id == tag_id))



  # --------------------CALLBACK--------------------------

  @impl true
  def init(_opts) do
    {:ok, nil}
  end


  def handle_call({:create_table, _gm_id}, _from, %Table{} = state) do
    {:reply, {:error, :already_existing}, state}
  end

  @impl true
  def handle_call({:create_table, gm_id}, _from, state) do
    case Registry.lookup(gm_id) do
      {:error, :not_found} ->
        {:reply, {:error, :unknown_tag}, state}

      {:ok, %Poker.Players.Player{gm: true} = player} ->
        table = %Table{
        table_id: Ecto.UUID.generate(),
        gm_id: gm_id,
        players: [
          %Player{
            id: gm_id,
            name: player.name,
            bankroll: player.bankroll,
            seat: 0
            }
          ]
        }

        {:reply, {:ok, table}, table}
      {:ok, %Poker.Players.Player{gm: false}} ->
        {:reply, {:error, :not_gm}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:join, tag_id}, _from, state) do
    #est-ce que le joueur est déjà enregistré ?
    cond do
      Enum.find(state.players, &(&1.id == tag_id)) != nil ->
        {:reply, {:error, :player_already_registered}, state}

      length(state.players) >= Table.max_players() ->
        {:reply, {:error, :table_full}, state}

      state.status == :playing ->
        {:reply, {:error, :game_already_started}, state}
      true ->
        case Registry.lookup(tag_id) do
          {:error, :not_found} ->
            {:reply, {:error, :unknown_tag}, state}

          {:ok, player} ->

            players = state.players ++ [
              %Player{
              id: tag_id,
              name: player.name,
              bankroll: player.bankroll,
              seat: length(state.players)
              }]

            table = %Table{state | players: players}
            {:reply, {:ok, table}, table}
        end
    end
  end

  @impl true
  def handle_call({:start_game, caller_id}, _from, state) do
    cond do
      length(state.players) < 2 ->
        {:reply, {:error, :not_enough_players}, state}
      state.status == :playing ->
        {:reply, {:error, :game_already_started}, state}

      state.gm_id == caller_id ->
        table = %Table{state | status: :playing}
        {:reply, {:ok, table}, table}

      state.gm_id != caller_id ->
        {:reply, {:error, :not_gm}, state}
    end
  end
end
