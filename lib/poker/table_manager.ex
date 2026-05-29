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
      # String UUID — identifiant unique de la table
      :table_id,
      # String — tag NFC du joueur ayant le rôle GM
      :gm_id,
      # [%Player{}] dans l'ordre de scan (= ordre des seats)
      players: [],
      # :waiting | :playing
      status: :waiting,
      # %Hand{} | nil
      hand: nil,
      # Integer — index dans `players` du dealer actuel (-1 = pas encore joué)
      dealer_seat: -1,
      small_blind: 10,
      big_blind: 20
    ]

    def max_players(), do: 6
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
      # String — tag NFC, clé primaire SQLite
      :id,
      # String — pseudo (lu depuis SQLite à la connexion)
      :name,
      # Integer — bankroll en cours (= SQLite players.bankroll)
      :bankroll,
      # :active | :folded | :all_in | :out
      status: :active
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
      # Integer — pot principal cumulé
      :pot,
      # :preflop | :flop | :turn | :river | :showdown
      :current_round,
      # Integer — index dans Table.players du joueur à agir
      :current_player_seat,
      # Integer | nil — montant de la dernière relance
      :last_raise,
      # %{player_id => integer} mises du tour en cours
      :bets,
      # %{player_id => integer} mises totales de la main
      :total_bets,
      # Integer : 0 (preflop) | 3 (flop) | 4 (turn) | 5 (river)
      :community_cards_count,
      # [{amount, [eligible_ids]}] — pots à distribuer à l'abattage, du principal au side pot
      remaining_pots: [],
      # seats ayant agi ce tour (pour détecter fin de round)
      acted_seats: MapSet.new()
    ]
  end

  # ---------------------------------------------------------------------------
  # API publique — documentation des fonctions à implémenter
  # ---------------------------------------------------------------------------
  use GenServer
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
  @spec create_table(String.t()) ::
          {:ok, struct()} | {:error, :invalid_tag} | {:error, :already_existing}
  def create_table(gm_id) when is_binary(gm_id) do
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
  def reset_table(caller_tag), do: GenServer.call(__MODULE__, {:reset_table, caller_tag})

  def new_hand(caller_tag), do: GenServer.call(__MODULE__, {:new_hand, caller_tag})

  def fold(caller_tag), do: GenServer.call(__MODULE__, {:fold, caller_tag})

  @doc """
  Le joueur égalise la mise la plus haute du tour en cours.

  Le montant à payer = `max(Map.values(hand.bets)) - hand.bets[caller_id]`
  (ou juste `max(bets)` si le joueur n'a encore rien misé ce tour).

  Si le joueur n'a pas assez pour égaliser, il paie tout ce qu'il lui reste
  et passe automatiquement en `:all_in` (c'est un "call partiel").

  Après le call, avancer au joueur suivant puis vérifier si le tour est terminé
  (voir indice `round_complete?` plus bas).

  ## Paramètres
  - `caller_tag` — String, tag NFC du joueur (doit être `current_player_seat`)

  ## Retours
  - `{:ok, %Table{}}` — mise égalisée, état mis à jour
  - `{:error, :not_your_turn}` — ce n'est pas le tour de ce joueur
  - `{:error, :no_bet_to_call}` — aucune mise ouverte, il faut checker ou raiser
  """
  def call(caller_tag), do: GenServer.call(__MODULE__, {:call, caller_tag})

  @doc """
  Le joueur passe sans miser (action neutre).

  Uniquement autorisé si le joueur n'a rien à égaliser ce tour :
  `(hand.bets[caller_id] || 0) == max_bet_du_tour`.

  Au preflop, seule la BB peut checker si personne n'a relancé
  (elle a déjà misé la BB, donc max_bet == big_blind == sa mise).

  Après le check, avancer au joueur suivant puis vérifier si le tour est terminé.

  ## Paramètres
  - `caller_tag` — String, tag NFC du joueur (doit être `current_player_seat`)

  ## Retours
  - `{:ok, %Table{}}` — check accepté
  - `{:error, :not_your_turn}` — ce n'est pas le tour de ce joueur
  - `{:error, :must_call_or_raise}` — il y a une mise ouverte, impossible de checker
  """
  def check(caller_tag), do: GenServer.call(__MODULE__, {:check, caller_tag})

  @doc """
  Le joueur mise un montant supérieur à la mise maximale en cours.

  `amount` représente le **total** mis par ce joueur dans la pot ce tour
  (pas le delta). Le paiement net = `amount - (hand.bets[caller_id] || 0)`.

  Exemple : la BB a mis 20, elle relance à 100 → `amount=100`, elle paie 80 de plus.

  Validations :
  - `amount >= max(big_blind, hand.last_raise || 0)` sinon `:raise_too_small`
  - `paiement_net <= bankroll` sinon `:insufficient_funds`

  Après une relance, `last_raise` prend la valeur de `amount`, et **tous** les
  joueurs actifs devront à nouveau agir (y compris ceux qui avaient déjà callé).
  Indice : stocker `last_aggressor_seat` dans `Hand` permet de savoir quand le
  tour se referme (le tour finit quand on revient à ce siège sans nouvelle relance).

  ## Paramètres
  - `caller_tag` — String, tag NFC du joueur (doit être `current_player_seat`)
  - `amount` — Integer, total misé par ce joueur ce tour (>= 0)

  ## Retours
  - `{:ok, %Table{}}` — relance acceptée
  - `{:error, :not_your_turn}` — ce n'est pas le tour de ce joueur
  - `{:error, :raise_too_small}` — montant inférieur à la BB ou au dernier raise
  - `{:error, :insufficient_funds}` — pas assez de bankroll
  """
  def raise_bet(caller_tag, amount),
    do: GenServer.call(__MODULE__, {:raise_bet, caller_tag, amount})

  @doc """
  Le joueur mise la totalité de son bankroll restant.

  C'est un raccourci pour un raise/call au maximum : le joueur paie tout ce
  oui corriqu'il lui reste, son bankroll passe à 0 et son statut passe à `:all_in`.

  Si son all-in est **inférieur** à la mise maximale en cours, l'action
  n'ouvre pas l'enchère (les autres joueurs ne peuvent pas re-raiser au-dessus
  de ce montant vis-à-vis de ce joueur → side pot à calculer).
  Indice : `side_pots` se calcule à partir de `total_bets` en fin de main.

  Si son all-in est **supérieur** à la mise maximale, c'est équivalent à un
  raise : `last_raise` et `last_aggressor_seat` sont mis à jour.

  Le joueur en `:all_in` est ensuite **ignoré** par `next_player/2`.

  ## Paramètres
  - `caller_tag` — String, tag NFC du joueur (doit être `current_player_seat`)

  ## Retours
  - `{:ok, %Table{}}` — all-in accepté
  - `{:error, :not_your_turn}` — ce n'est pas le tour de ce joueur
  """
  def all_in(caller_tag), do: GenServer.call(__MODULE__, {:all_in, caller_tag})

  def declare_winner(caller_tag, winner_id),
    do: GenServer.call(__MODULE__, {:declare_winner, caller_tag, winner_id})

  # ---------------------------------------------------------------------------
  # Fonctions privées utilitaires — à implémenter dans le module
  # ---------------------------------------------------------------------------

  # round_complete?(table) → boolean
  #
  # Un tour de mise est terminé quand :
  #   1. Tous les joueurs :active ont la même mise dans hand.bets
  #      (les :all_in sont exclus — ils ne peuvent plus agir)
  #   2. ET le siège courant est `last_aggressor_seat` (le tour a fait le tour complet)
  #
  # `last_aggressor_seat` est initialisé à la BB au preflop et au premier actif
  # après le dealer en post-flop. Il est mis à jour à chaque raise/all_in.
  # → Ajouter ce champ à Hand.
  #
  # Quand round_complete? renvoie true :
  #   - Remettre hand.bets à %{}
  #   - Passer au round suivant (:preflop → :flop → :turn → :river → :showdown)
  #   - Mettre à jour community_cards_count (0→3→4→5→5)
  #   - Recalculer le premier joueur à agir (premier :active après dealer_seat)
  #   - Recalculer last_aggressor_seat pour le nouveau tour

  defp validate_action(state, caller_id) do
    current_player = Enum.at(state.players, state.hand.current_player_seat)

    cond do
      state.hand.current_round == :showdown -> {:error, :showdown_no_actions}
      caller_id != current_player.id -> {:error, :not_your_turn}
      true -> :ok
    end
  end

  defp advance_action(table, actor_seat, new_bets) do
    acted = MapSet.put(table.hand.acted_seats, actor_seat)

    active_seats =
      table.players
      |> Enum.with_index()
      |> Enum.filter(fn {p, _} -> p.status == :active end)
      |> Enum.map(fn {_, i} -> i end)

    max_bet = new_bets |> Map.values() |> Enum.max(fn -> 0 end)

    all_acted = Enum.all?(active_seats, &MapSet.member?(acted, &1))

    all_equal =
      Enum.all?(active_seats, fn i ->
        Map.get(new_bets, Enum.at(table.players, i).id, 0) == max_bet
      end)

    if all_acted and all_equal do
      advance_round(%Table{table | hand: %Hand{table.hand | acted_seats: acted}})
    else
      next = next_player(table.players, actor_seat)

      %Table{
        table
        | hand: %Hand{table.hand | bets: new_bets, acted_seats: acted, current_player_seat: next}
      }
    end
  end

  defp advance_round(table) do
    {next_round, cc_count} =
      case table.hand.current_round do
        :preflop -> {:flop, 3}
        :flop -> {:turn, 4}
        :turn -> {:river, 5}
        :river -> {:showdown, 5}
        :showdown -> {:showdown, 5}
      end

    n = length(table.players)

    first_active_seat =
      Enum.find(1..n, fn offset ->
        seat = rem(table.dealer_seat + offset, n)
        Enum.at(table.players, seat).status == :active
      end)
      |> case do
        nil -> table.hand.current_player_seat
        offset -> rem(table.dealer_seat + offset, n)
      end

    remaining_pots =
      if next_round == :showdown do
        compute_pots(table.players, table.hand.total_bets)
      else
        []
      end

    hand = %Hand{
      table.hand
      | current_round: next_round,
        community_cards_count: cc_count,
        bets: %{},
        acted_seats: MapSet.new(),
        current_player_seat: first_active_seat,
        last_raise: nil,
        remaining_pots: remaining_pots
    }

    %Table{table | hand: hand}
  end

  defp compute_pots(players, total_bets) do
    all_caps =
      total_bets
      |> Map.values()
      |> Enum.sort()
      |> Enum.uniq()

    {pots, _} =
      Enum.reduce(all_caps, {[], 0}, fn cap, {pots, prev_cap} ->
        amount =
          Enum.reduce(players, 0, fn p, acc ->
            contrib = Map.get(total_bets, p.id, 0)
            if contrib > prev_cap, do: acc + min(contrib, cap) - prev_cap, else: acc
          end)

        eligible =
          players
          |> Enum.filter(fn p ->
            p.status not in [:folded, :out] and Map.get(total_bets, p.id, 0) >= cap
          end)
          |> Enum.map(& &1.id)

        {pots ++ [{amount, eligible}], cap}
      end)

    # Fusionner les pots consécutifs ayant les mêmes éligibles
    pots
    |> Enum.reduce([], fn {amount, eligible}, acc ->
      case acc do
        [{prev_amount, ^eligible} | rest] -> [{prev_amount + amount, eligible} | rest]
        _ -> [{amount, eligible} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp broadcast!(table) do
    Phoenix.PubSub.broadcast!(Poker.PubSub, "table", {:table_updated, table})
  end

  @spec is_gm?(String.t(), %Table{}) :: boolean()
  defp is_gm?(tag_id, table), do: table.gm_id == tag_id

  defp game_started?(table), do: table.status == :playing

  defp post_blinds(players, dealer_seat, small_blind, big_blind) do
    n = length(players)
    sb_seat = rem(dealer_seat + 1, n)
    bb_seat = rem(dealer_seat + 2, n)

    sb_id = Enum.at(players, sb_seat).id
    bb_id = Enum.at(players, bb_seat).id

    sb_amount = min(Enum.at(players, sb_seat).bankroll, small_blind)
    bb_amount = min(Enum.at(players, bb_seat).bankroll, big_blind)

    players =
      Enum.map(players, fn
        %Player{id: ^sb_id} = p ->
          status = if sb_amount == p.bankroll, do: :all_in, else: :active
          %{p | bankroll: p.bankroll - sb_amount, status: status}

        %Player{id: ^bb_id} = p ->
          status = if bb_amount == p.bankroll, do: :all_in, else: :active
          %{p | bankroll: p.bankroll - bb_amount, status: status}

        p ->
          p
      end)

    bets = %{sb_id => sb_amount, bb_id => bb_amount}

    {players, bets}
  end

  defp next_player(players, current_seat) do
    n = length(players)
    # On génère les potentielles prochaines places
    seats = Enum.map(1..(n - 1), fn offset -> rem(current_seat + offset, n) end)
    # On renvoit la premiere qui est active
    Enum.find(seats, fn seat -> Enum.at(players, seat).status == :active end)
  end

  defp end_hand(table) do
    persist_bankrolls(table.players)

    players =
      Enum.map(table.players, fn
        %Player{bankroll: 0} = p -> %{p | status: :out}
        %Player{status: s} = p when s in [:folded, :all_in] -> %{p | status: :active}
        p -> p
      end)

    %Table{table | hand: nil, players: players}
  end

  defp persist_bankrolls(players) do
    Enum.each(players, fn player ->
      case Registry.lookup(player.id) do
        {:ok, registry_player} ->
          delta = player.bankroll - registry_player.bankroll
          if delta != 0, do: Registry.update_bankroll(player.id, delta)

        _ ->
          :ok
      end
    end)
  end

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
          players: [%Player{id: gm_id, name: player.name, bankroll: player.bankroll}]
        }

        broadcast!(table)
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
    # est-ce que le joueur est déjà enregistré ?
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
            if player.bankroll < state.big_blind do
              {:reply, {:error, :not_enough_money}, state}
            else
              players =
                state.players ++
                  [
                    %Player{id: tag_id, name: player.name, bankroll: player.bankroll}
                  ]

              table = %Table{state | players: players}
              broadcast!(table)
              {:reply, {:ok, table}, table}
            end
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
        broadcast!(table)
        {:reply, {:ok, table}, table}

      state.gm_id != caller_id ->
        {:reply, {:error, :not_gm}, state}
    end
  end

  @impl true
  def handle_call({:reset_table, gm_id}, _from, state) do
    case Registry.lookup(gm_id) do
      {:error, :not_found} ->
        {:reply, {:error, :unknown_tag}, state}

      {:ok, %Poker.Players.Player{gm: true} = player} ->
        table = %Table{
          table_id: state.table_id,
          gm_id: gm_id,
          players: [%Player{id: gm_id, name: player.name, bankroll: player.bankroll}]
        }

        broadcast!(table)
        {:reply, {:ok, table}, table}

      {:ok, %Poker.Players.Player{gm: false}} ->
        {:reply, {:error, :not_gm}, state}
    end
  end

  def handle_call({:new_hand, gm_id}, _from, state) do
    active_players = Enum.reject(state.players, &(&1.status == :out))

    cond do
      not is_gm?(gm_id, state) ->
        {:reply, {:error, :not_gm}, state}

      not game_started?(state) ->
        {:reply, {:error, :game_not_started}, state}

      length(active_players) < 2 ->
        {:reply, {:error, :not_enough_players}, state}

      true ->
        players =
          Enum.map(active_players, fn
            %Player{status: status} = p when status in [:folded, :all_in] ->
              %{p | status: :active}

            p ->
              p
          end)

        new_dealer = rem(state.dealer_seat + 1, length(players))
        {players, bets} = post_blinds(players, new_dealer, state.small_blind, state.big_blind)
        utg = rem(new_dealer + 3, length(players))

        hand = %Hand{
          current_round: :preflop,
          community_cards_count: 0,
          bets: bets,
          total_bets: bets,
          pot: state.small_blind + state.big_blind,
          last_raise: nil,
          current_player_seat: utg
        }

        table = %Table{state | dealer_seat: new_dealer, players: players, hand: hand}
        broadcast!(table)
        {:reply, {:ok, table}, table}
    end
  end

  @impl true
  def handle_call({:fold, caller_id}, _from, state) do
    case validate_action(state, caller_id) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      :ok ->
        updated_players =
          Enum.map(state.players, fn
            %Player{id: ^caller_id} = player -> %{player | status: :folded}
            player -> player
          end)

        if Enum.count(updated_players, fn player -> player.status in [:active, :all_in] end) > 1 do
          updated_table = %Table{
            state
            | players: updated_players,
              hand: %Hand{
                state.hand
                | current_player_seat: next_player(updated_players, state.hand.current_player_seat)
              }
          }

          broadcast!(updated_table)
          {:reply, {:ok, updated_table}, updated_table}
        else
          winner = Enum.find(updated_players, fn player -> player.status in [:active, :all_in] end)
          winner_id = winner.id
          pot = state.hand.pot

          credited =
            Enum.map(updated_players, fn
              %Player{id: ^winner_id} = p -> %{p | bankroll: p.bankroll + pot}
              p -> p
            end)

          updated_table = end_hand(%Table{state | players: credited})
          broadcast!(updated_table)
          {:reply, {:ok, updated_table}, updated_table}
        end
    end
  end

  def handle_call({:check, caller_id}, _from, state) do
    actor_seat = state.hand.current_player_seat

    case validate_action(state, caller_id) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      :ok ->
        if Map.get(state.hand.bets, caller_id, 0) <
             (state.hand.bets |> Map.values() |> Enum.max(fn -> 0 end)) do
          {:reply, {:error, :must_call_or_raise}, state}
        else
          table = advance_action(state, actor_seat, state.hand.bets)
          broadcast!(table)
          {:reply, {:ok, table}, table}
        end
    end
  end

  def handle_call({:call, caller_id}, _from, state) do
    actor_seat = state.hand.current_player_seat
    current_player = Enum.at(state.players, actor_seat)

    case validate_action(state, caller_id) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      :ok ->
        max_bet = state.hand.bets |> Map.values() |> Enum.max(fn -> 0 end)
        my_bet = Map.get(state.hand.bets, caller_id, 0)
        actual = min(max_bet - my_bet, current_player.bankroll)

        players =
          Enum.map(state.players, fn
            %Player{id: ^caller_id} = p ->
              %{p | bankroll: p.bankroll - actual, status: if(p.bankroll == actual, do: :all_in, else: :active)}
            p -> p
          end)

        bets = Map.put(state.hand.bets, caller_id, my_bet + actual)
        total_bets = Map.update(state.hand.total_bets, caller_id, actual, &(&1 + actual))
        hand = %Hand{state.hand | bets: bets, total_bets: total_bets, pot: state.hand.pot + actual}
        table = advance_action(%Table{state | players: players, hand: hand}, actor_seat, bets)
        broadcast!(table)
        {:reply, {:ok, table}, table}
    end
  end

  def handle_call({:all_in, caller_id}, _from, state) do
    actor_seat = state.hand.current_player_seat
    current_player = Enum.at(state.players, actor_seat)

    case validate_action(state, caller_id) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      :ok ->
      amount = current_player.bankroll
      my_bet = Map.get(state.hand.bets, caller_id, 0)
      max_bet = state.hand.bets |> Map.values() |> Enum.max(fn -> 0 end)
      is_raise = my_bet + amount > max_bet

      players =
        Enum.map(state.players, fn
          %Player{id: ^caller_id} = p -> %{p | bankroll: 0, status: :all_in}
          p -> p
        end)

      bets = Map.put(state.hand.bets, caller_id, my_bet + amount)
      total_bets = Map.update(state.hand.total_bets, caller_id, amount, &(&1 + amount))

      hand = %Hand{
        state.hand
        | bets: bets,
          total_bets: total_bets,
          pot: state.hand.pot + amount
      }

      table =
        if is_raise do
          next = next_player(players, actor_seat)

          %Table{
            state
            | players: players,
              hand: %Hand{hand | acted_seats: MapSet.new([actor_seat]), current_player_seat: next}
          }
        else
          advance_action(%Table{state | players: players, hand: hand}, actor_seat, bets)
        end

      broadcast!(table)
      {:reply, {:ok, table}, table}
    end
  end

  def handle_call({:raise_bet, caller_id, amount}, _from, state) do
    actor_seat = state.hand.current_player_seat
    current_player = Enum.at(state.players, actor_seat)
    min_raise = max(state.big_blind, state.hand.last_raise || 0)

    case validate_action(state, caller_id) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      :ok ->
    cond do
      amount < min_raise ->
        {:reply, {:error, :raise_too_small}, state}

      amount > current_player.bankroll ->
        {:reply, {:error, :insufficient_funds}, state}

      true ->
        my_bet = Map.get(state.hand.bets, caller_id, 0)

        players =
          Enum.map(state.players, fn
            %Player{id: ^caller_id} = p ->
              %{
                p
                | bankroll: p.bankroll - amount,
                  status: if(p.bankroll == amount, do: :all_in, else: :active)
              }

            p ->
              p
          end)

        bets = Map.put(state.hand.bets, caller_id, my_bet + amount)
        total_bets = Map.update(state.hand.total_bets, caller_id, amount, &(&1 + amount))
        next = next_player(players, actor_seat)

        hand = %Hand{
          state.hand
          | bets: bets,
            total_bets: total_bets,
            pot: state.hand.pot + amount,
            last_raise: my_bet + amount,
            acted_seats: MapSet.new([actor_seat]),
            current_player_seat: next
        }

        table = %Table{state | players: players, hand: hand}
        broadcast!(table)
        {:reply, {:ok, table}, table}
    end
  end
  end

  def handle_call({:declare_winner, caller_id, winner_id}, _from, state) do
    cond do
      not is_gm?(caller_id, state) ->
        {:reply, {:error, :not_gm}, state}

      state.hand == nil or state.hand.current_round != :showdown ->
        {:reply, {:error, :not_showdown}, state}

      state.hand.remaining_pots == [] ->
        {:reply, {:error, :no_pots_remaining}, state}

      true ->
        [{amount, eligible} | rest_pots] = state.hand.remaining_pots

        if winner_id not in eligible do
          {:reply, {:error, :player_not_eligible}, state}
        else
          players =
            Enum.map(state.players, fn
              %Player{id: ^winner_id} = p -> %{p | bankroll: p.bankroll + amount}
              p -> p
            end)

          if Enum.empty?(rest_pots) do
            table = end_hand(%Table{state | players: players})
            broadcast!(table)
            {:reply, {:ok, table}, table}
          else
            hand = %Hand{state.hand | remaining_pots: rest_pots}
            table = %Table{state | players: players, hand: hand}
            broadcast!(table)
            {:reply, {:ok, table}, table}
          end
        end
    end
  end
end
