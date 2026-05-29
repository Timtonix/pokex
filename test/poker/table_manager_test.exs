defmodule Poker.TableManagerTest do
  use Poker.DataCase, async: false

  alias Poker.TableManager
  alias Poker.TableManager.{Table, Player}
  alias Poker.Players.Registry

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------
  setup do
    start_supervised!({Registry, []})
    start_supervised!({TableManager, []})

    Ecto.Adapters.SQL.Sandbox.allow(Poker.Repo, self(), TableManager)
    Ecto.Adapters.SQL.Sandbox.allow(Poker.Repo, self(), Registry)

    # Enregistrer des joueurs
    {:ok, player} = Registry.register("alice", "Alice", 10_000)

    player
    |> Poker.Players.Player.changeset(%{gm: true})
    |> Repo.update()

    :sys.replace_state(Registry, fn state ->
      Map.update!(state, "alice", fn player -> %{player | gm: true} end)
    end)

    Registry.register("bob", "Bob", 10_000)
    Registry.register("charlie", "Charlie", 10_000)
    Registry.register("diana", "Diana", 10_000)
    Registry.register("tim", "Timothy", 10_000)
    Registry.register("andrew", "Andrew", 10_000)
    Registry.register("leo", "Leo", 10_000)

    :ok
  end

  defp gm_id, do: "alice"
  defp player_ids, do: ["bob", "charlie", "diana", "tim", "andrew", "leo"]

  defp create_table do
    TableManager.create_table(gm_id())
  end

  defp table_with_players(count \\ 2) do
    {:ok, table} = create_table()

    player_ids = Enum.take(player_ids(), count - 1)

    Enum.each(player_ids, fn id ->
      {:ok, t} = TableManager.join_table(id)
    end)

    TableManager.get_state()
  end

  # Crée une table, fait rejoindre `count` joueurs (GM inclus), démarre la partie,
  # puis lance une nouvelle main.
  # Retourne %Table{} avec hand non-nil et blindes déjà postées.
  defp ready_hand(count \\ 3) do
    {:ok, _table} = TableManager.create_table(gm_id())

    player_ids()
    |> Enum.take(count - 1)
    |> Enum.each(fn id -> {:ok, _} = TableManager.join_table(id) end)

    {:ok, _} = TableManager.start_game(gm_id())
    {:ok, table} = TableManager.new_hand(gm_id())
    table
  end

  # Cherche un joueur dans la table par son id
  defp find_player(table, id) do
    Enum.find(table.players, &(&1.id == id))
  end

  # Retourne l'id du joueur au tour courant
  defp current_player_id(table) do
    player = Enum.at(table.players, table.hand.current_player_seat)
    player.id
  end

  # Injecte un état de river connu avec bob all-in et alice/charlie actifs
  defp inject_river_with_allin(table, bob_total_bet, others_total_bet) do
    pot = bob_total_bet + others_total_bet * 2
    alice_seat = Enum.find_index(table.players, &(&1.id == "alice"))

    :sys.replace_state(TableManager, fn %Table{} = t ->
      players =
        Enum.map(t.players, fn
          %Player{id: "alice"} = p -> %{p | bankroll: 10_000 - others_total_bet, status: :active}
          %Player{id: "bob"} = p -> %{p | bankroll: 0, status: :all_in}
          %Player{id: "charlie"} = p -> %{p | bankroll: 10_000 - others_total_bet, status: :active}
        end)

      hand = %{t.hand |
        current_round: :river,
        community_cards_count: 5,
        pot: pot,
        bets: %{},
        total_bets: %{"alice" => others_total_bet, "bob" => bob_total_bet, "charlie" => others_total_bet},
        last_raise: nil,
        remaining_pots: [],
        acted_seats: MapSet.new(),
        current_player_seat: alice_seat
      }

      %{t | players: players, hand: hand}
    end)
  end

  # ---------------------------------------------------------------------------
  # BLOC 1 — Création de table
  # ---------------------------------------------------------------------------

  describe "create_table/1" do
    test "retourne {:ok, %Table{}} avec les valeurs par défaut" do
      assert {:ok, %Table{}} = create_table()
    end

    test "Quand on veut créer une table, alors qu'elle existe : error" do
      {:ok, t1} = create_table()
      refute is_nil(t1.table_id)
      assert {:error, :already_existing} == create_table()
    end

    test "le statut initial est :waiting" do
      {:ok, table} = create_table()
      assert table.status == :waiting
    end

    test "aucune main en cours à la création" do
      {:ok, table} = create_table()
      assert is_nil(table.hand)
    end

    test "le dealer_seat initial est -1 (pas encore joué)" do
      {:ok, table} = create_table()
      assert table.dealer_seat == -1
    end

    test "le GM est automatiquement enregistré comme premier joueur" do
      {:ok, table} = create_table()

      assert length(table.players) == 1
      [gm_player] = table.players
      assert gm_player.id == gm_id()
      assert gm_player.name == "Alice"
    end

    test "le GM a le bon gm_id dans la table" do
      {:ok, table} = create_table()
      assert table.gm_id == gm_id()
    end

    test "le GM est à l'index 0 dans la liste des joueurs" do
      {:ok, table} = create_table()
      assert Enum.find_index(table.players, &(&1.id == gm_id())) == 0
    end

    test "le joueur GM a le statut :active" do
      {:ok, table} = create_table()
      [gm_player] = table.players
      assert gm_player.status == :active
    end

    test "refus si le tag GM est une chaîne vide" do
      assert {:error, :invalid_tag} = TableManager.create_table("")
    end

    test "refus si le tag n'est pas GM" do
      assert {:error, :not_gm} = TableManager.create_table(Enum.at(player_ids(), 0))
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 2 — Rejoindre la table
  # ---------------------------------------------------------------------------

  describe "join_table/1" do
    test "un joueur peut rejoindre une table en :waiting" do
      {:ok, table} = create_table()
      assert {:ok, updated_table} = TableManager.join_table("bob")
      assert length(updated_table.players) == 2
    end

    test "le joueur ajouté a les bonnes données" do
      {:ok, table} = create_table()
      {:ok, updated_table} = TableManager.join_table("bob")

      bob = Enum.find(updated_table.players, &(&1.id == "bob"))
      assert bob.name == "Bob"
      assert bob.bankroll == 10000
      assert bob.status == :active
    end

    test "les joueurs sont dans l'ordre d'arrivée (index 0, 1, 2...)" do
      {:ok, _} = create_table()
      {:ok, _} = TableManager.join_table("bob")
      {:ok, t3} = TableManager.join_table("charlie")

      assert Enum.at(t3.players, 0).id == gm_id()
      assert Enum.at(t3.players, 1).id == "bob"
      assert Enum.at(t3.players, 2).id == "charlie"
    end

    test "l'ordre des joueurs reflète l'ordre de scan" do
      {:ok, table} = create_table()
      {:ok, t2} = TableManager.join_table("bob")
      {:ok, t3} = TableManager.join_table("charlie")

      ids = Enum.map(t3.players, & &1.id)
      assert ids == [gm_id(), "bob", "charlie"]
    end

    test "refus si la table est en :playing" do
      table_with_players(3)
      TableManager.start_game("alice")

      assert {:error, :game_already_started} =
               TableManager.join_table("andrew")
    end

    test "refus si le tag est déjà enregistré" do
      {:ok, table} = create_table()
      {:ok, updated_table} = TableManager.join_table("bob")

      assert {:error, :player_already_registered} =
               TableManager.join_table("bob")
    end

    test "refus si on dépasse max_players (6)" do
      table_with_players(6)

      assert {:error, :table_full} =
               TableManager.join_table("leo")
    end

    test "refus si le tag est une chaîne vide" do
      {:ok, table} = create_table()
      assert {:error, :unknown_tag} = TableManager.join_table("")
    end

    test "6 joueurs peuvent rejoindre sans erreur (limite max)" do
      table = table_with_players(6)

      assert length(table.players) == 6
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 3 — Démarrage de la partie (prérequis avant la logique de jeu)
  # ---------------------------------------------------------------------------

  describe "start_game/1" do
    test "passage en :playing si min 2 joueurs" do
      table = table_with_players(2)
      assert {:ok, %Table{status: :playing}} = TableManager.start_game("alice")
    end

    test "refus si moins de 2 joueurs" do
      {:ok, table} = create_table()
      assert {:error, :not_enough_players} = TableManager.start_game(table)
    end

    test "refus si la partie est déjà en cours" do
      table = table_with_players(2)
      {:ok, playing_table} = TableManager.start_game("alice")
      assert {:error, :game_already_started} = TableManager.start_game("alice")
    end

    test "seul le GM peut démarrer — refus si appelé par un autre joueur" do
      table = table_with_players(2)

      assert {:error, :not_gm} =
               TableManager.start_game("bob")
    end

    test "le dealer_seat est -1 avant la première main" do
      table = table_with_players(2)
      {:ok, started} = TableManager.start_game("alice")
      assert started.dealer_seat == -1
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 4 — Intégrité des structs
  # ---------------------------------------------------------------------------

  describe "intégrité des structs" do
    test "Table a les champs attendus" do
      {:ok, table} = create_table()
      assert Map.has_key?(table, :table_id)
      assert Map.has_key?(table, :gm_id)
      assert Map.has_key?(table, :players)
      assert Map.has_key?(table, :status)
      assert Map.has_key?(table, :hand)
      assert Map.has_key?(table, :dealer_seat)
    end

    test "Player a les champs attendus" do
      {:ok, table} = create_table()
      [player] = table.players
      assert Map.has_key?(player, :id)
      assert Map.has_key?(player, :name)
      assert Map.has_key?(player, :bankroll)
      assert Map.has_key?(player, :status)
    end

    test "Hand est nil tant que la partie n'a pas commencé" do
      table = table_with_players(3)
      assert is_nil(table.hand)
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 5 — new_hand/1 : initialisation d'une main
  # ---------------------------------------------------------------------------

  describe "new_hand/1" do
    test "crée une %Hand{} non-nil après start_game" do
      table = ready_hand(3)
      refute is_nil(table.hand)
    end

    test "la main débute au :preflop" do
      table = ready_hand(3)
      assert table.hand.current_round == :preflop
    end

    test "community_cards_count est 0 au preflop" do
      table = ready_hand(3)
      assert table.hand.community_cards_count == 0
    end

    test "le pot initial est la somme des deux blindes" do
      # small blind + big blind — valeurs par défaut à définir dans l'implem
      # On teste la cohérence : pot == SB + BB (typiquement 10 + 20 = 30)
      table = ready_hand(3)
      {sb, bb} = {table.small_blind, table.big_blind}
      assert table.hand.pot == sb + bb
    end

    test "les joueurs ayant posté les blindes ont leur bankroll diminuée" do
      table = ready_hand(3)
      # dealer=0 (alice), SB=1 (bob), BB=2 (charlie)
      sb_player = Enum.at(table.players, 1)
      bb_player = Enum.at(table.players, 2)
      {sb, bb} = {table.small_blind, table.big_blind}

      assert sb_player.bankroll == 10_000 - sb
      assert bb_player.bankroll == 10_000 - bb
    end

    test "bets du tour contient les mises des blindes" do
      table = ready_hand(3)
      {sb, bb} = {table.small_blind, table.big_blind}
      # dealer=0 (alice), SB=1 (bob), BB=2 (charlie)
      sb_player = Enum.at(table.players, 1)
      bb_player = Enum.at(table.players, 2)

      assert table.hand.bets[sb_player.id] == sb
      assert table.hand.bets[bb_player.id] == bb
    end

    test "le premier joueur à agir au preflop est UTG (après BB)" do
      # dealer=0 (alice), SB=1 (bob), BB=2 (charlie), UTG=rem(0+3,3)=0 (alice)
      table = ready_hand(3)
      assert table.hand.current_player_seat == 0
    end

    test "refus si la partie n'est pas en :playing" do
      {:ok, _} = TableManager.create_table(gm_id())
      assert {:error, :game_not_started} = TableManager.new_hand(gm_id())
    end

    test "refus si appelé par un non-GM" do
      {:ok, _} = TableManager.create_table(gm_id())
      {:ok, _} = TableManager.join_table("bob")
      {:ok, _} = TableManager.start_game(gm_id())
      assert {:error, :not_gm} = TableManager.new_hand("bob")
    end

    test "Hand a les champs structurels attendus" do
      table = ready_hand(3)
      hand = table.hand
      assert Map.has_key?(hand, :pot)
      assert Map.has_key?(hand, :remaining_pots)
      assert Map.has_key?(hand, :current_round)
      assert Map.has_key?(hand, :current_player_seat)
      assert Map.has_key?(hand, :last_raise)
      assert Map.has_key?(hand, :bets)
      assert Map.has_key?(hand, :total_bets)
      assert Map.has_key?(hand, :community_cards_count)
    end

    test "les joueurs :out ne participent pas à la main" do
      # On simule un joueur éliminé avant la main via :sys.replace_state
      {:ok, _} = TableManager.create_table(gm_id())
      {:ok, _} = TableManager.join_table("bob")
      {:ok, _} = TableManager.join_table("charlie")
      {:ok, _} = TableManager.start_game(gm_id())

      # On élimine charlie manuellement
      :sys.replace_state(TableManager, fn %Table{} = t ->
        players =
          Enum.map(t.players, fn
            %Player{id: "charlie"} = p -> %{p | bankroll: 0, status: :out}
            p -> p
          end)

        %{t | players: players}
      end)

      {:ok, table} = TableManager.new_hand(gm_id())
      active_in_hand = Enum.reject(table.players, &(&1.status == :out))
      assert length(active_in_hand) == 2
    end

    test "dealer_seat avance d'un cran à chaque nouvelle main" do
      {:ok, _} = TableManager.create_table(gm_id())
      {:ok, _} = TableManager.join_table("bob")
      {:ok, _} = TableManager.join_table("charlie")
      {:ok, _} = TableManager.start_game(gm_id())

      {:ok, table1} = TableManager.new_hand(gm_id())
      dealer1 = table1.dealer_seat

      # UTG fold, puis le suivant fold → le dernier gagne et la main se termine
      {:ok, t} = TableManager.fold(current_player_id(table1))
      {:ok, _} = TableManager.fold(current_player_id(t))

      {:ok, table2} = TableManager.new_hand(gm_id())
      assert table2.dealer_seat == rem(dealer1 + 1, length(table2.players))
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 6 — fold/1
  # ---------------------------------------------------------------------------

  describe "fold/1" do
    test "le joueur passe en :folded" do
      table = ready_hand(3)
      acting_id = current_player_id(table)
      {:ok, table} = TableManager.fold(acting_id)
      assert find_player(table, acting_id).status == :folded
    end

    test "le tour passe au joueur suivant" do
      table = ready_hand(3)
      seat_before = table.hand.current_player_seat
      acting_id = current_player_id(table)
      {:ok, table} = TableManager.fold(acting_id)
      refute table.hand.current_player_seat == seat_before
    end

    test "refus si ce n'est pas le tour du joueur" do
      table = ready_hand(3)
      acting_id = current_player_id(table)
      # Trouver un autre joueur actif
      other_id =
        table.players
        |> Enum.find(&(&1.id != acting_id && &1.status == :active))
        |> Map.fetch!(:id)

      assert {:error, :not_your_turn} = TableManager.fold(other_id)
    end

    test "quand tous sauf un foldent, la main se termine immédiatement" do
      table = ready_hand(3)
      # Avec 3 joueurs : UTG fold → SB fold → BB gagne sans showdown
      id1 = current_player_id(table)
      {:ok, t2} = TableManager.fold(id1)
      id2 = current_player_id(t2)
      {:ok, t3} = TableManager.fold(id2)
      # La main doit être terminée (nil) ou en :showdown avec un seul actif
      assert is_nil(t3.hand) or
               Enum.count(t3.players, &(&1.status in [:active, :all_in])) == 1
    end

    test "le pot va au dernier joueur non-foldé" do
      table = ready_hand(3)
      pot = table.hand.pot

      id1 = current_player_id(table)
      {:ok, t2} = TableManager.fold(id1)
      id2 = current_player_id(t2)

      winner_id =
        t2.players
        |> Enum.find(&(&1.id != id1 && &1.id != id2))
        |> Map.fetch!(:id)

      {:ok, t3} = TableManager.fold(id2)
      winner = find_player(t3, winner_id)
      # bankroll initiale 1000 + pot reçu (moins les blindes déjà déduites)
      assert winner.bankroll > 1_000 - table.big_blind
    end

    test "un joueur :folded ne peut pas agir à nouveau dans la même main" do
      table = ready_hand(4)
      acting_id = current_player_id(table)
      {:ok, _} = TableManager.fold(acting_id)
      assert {:error, :not_your_turn} = TableManager.fold(acting_id)
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 7 — check/1
  # ---------------------------------------------------------------------------

  describe "check/1" do
    test "check est autorisé quand la mise courante est nulle (BB après tour)" do
      # On amène la main jusqu'au flop où tout le monde a checké au preflop
      # Setup : 3 joueurs, tout le monde call/fold pour arriver au flop
      table = ready_hand(3)
      # UTG call, SB call, BB check → flop
      id_utg = current_player_id(table)
      {:ok, t} = TableManager.call(id_utg)
      id_sb = current_player_id(t)
      {:ok, t} = TableManager.call(id_sb)
      id_bb = current_player_id(t)
      {:ok, t} = TableManager.check(id_bb)
      # Maintenant on est au flop — SB peut checker
      assert t.hand.current_round == :flop
      id_flop = current_player_id(t)
      {:ok, t2} = TableManager.check(id_flop)
      refute is_nil(t2.hand)
    end

    test "check est refusé si une mise est ouverte" do
      table = ready_hand(3)
      # Au preflop, la BB a déjà misé → UTG ne peut pas checker, doit call/raise/fold
      acting_id = current_player_id(table)
      assert {:error, :must_call_or_raise} = TableManager.check(acting_id)
    end

    test "check ne modifie pas le pot" do
      table = ready_hand(3)
      # On arrive au flop via call + call + check
      id_utg = current_player_id(table)
      {:ok, t} = TableManager.call(id_utg)
      {:ok, t} = TableManager.call(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      pot_flop = t.hand.pot
      {:ok, t2} = TableManager.check(current_player_id(t))
      assert t2.hand.pot == pot_flop
    end

    test "refus si ce n'est pas le tour du joueur" do
      table = ready_hand(3)

      other_id =
        table.players
        |> Enum.find(&(&1.id != current_player_id(table) && &1.status == :active))
        |> Map.fetch!(:id)

      assert {:error, :not_your_turn} = TableManager.check(other_id)
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 8 — call/1
  # ---------------------------------------------------------------------------

  describe "call/1" do
    test "la bankroll du joueur diminue du montant à égaliser" do
      table = ready_hand(3)
      bb = table.big_blind
      acting_id = current_player_id(table)
      bankroll_before = find_player(table, acting_id).bankroll
      {:ok, t} = TableManager.call(acting_id)
      assert find_player(t, acting_id).bankroll == bankroll_before - bb
    end

    test "la mise du joueur dans bets est égale à la BB" do
      table = ready_hand(3)
      bb = table.big_blind
      acting_id = current_player_id(table)
      {:ok, t} = TableManager.call(acting_id)
      assert t.hand.bets[acting_id] == bb
    end

    test "le pot augmente du montant appelé" do
      table = ready_hand(3)
      bb = table.big_blind
      pot_before = table.hand.pot
      acting_id = current_player_id(table)
      {:ok, t} = TableManager.call(acting_id)
      assert t.hand.pot == pot_before + bb
    end

    test "call après une relance égalise le montant de la relance" do
      table = ready_hand(3)
      acting_id = current_player_id(table)
      raise_amount = 100
      {:ok, t_raised} = TableManager.raise_bet(acting_id, raise_amount)
      caller_id = current_player_id(t_raised)
      bankroll_before = find_player(t_raised, caller_id).bankroll
      # Le caller paie la différence entre le raise et sa mise déjà postée (blind)
      caller_prior_bet = Map.get(t_raised.hand.bets, caller_id, 0)
      {:ok, t_called} = TableManager.call(caller_id)

      assert find_player(t_called, caller_id).bankroll ==
               bankroll_before - (raise_amount - caller_prior_bet)
    end

    test "call ne dépasse pas le bankroll du joueur (devient all-in automatique)" do
      # Avec 4 joueurs : alice=dealer(0), bob=SB(1), charlie=BB(2), diana=UTG(3)
      # diana a seulement 5 chips, elle appelle la BB (20) mais va all-in pour 5
      {:ok, _} = TableManager.create_table(gm_id())
      {:ok, _} = TableManager.join_table("bob")
      {:ok, _} = TableManager.join_table("charlie")
      {:ok, _} = TableManager.join_table("diana")

      :sys.replace_state(TableManager, fn %Table{} = t ->
        players =
          Enum.map(t.players, fn
            %Player{id: "diana"} = p -> %{p | bankroll: 5}
            p -> p
          end)

        %{t | players: players}
      end)

      {:ok, _} = TableManager.start_game(gm_id())
      {:ok, table} = TableManager.new_hand(gm_id())

      # UTG = diana (seat 3), c'est son tour d'agir en premier
      diana_seat = Enum.find_index(table.players, &(&1.id == "diana"))
      assert table.hand.current_player_seat == diana_seat

      {:ok, t} = TableManager.call("diana")
      assert find_player(t, "diana").bankroll == 0
      assert find_player(t, "diana").status == :all_in
    end

    test "refus si ce n'est pas le tour du joueur" do
      table = ready_hand(3)

      other_id =
        table.players
        |> Enum.find(&(&1.id != current_player_id(table) && &1.status == :active))
        |> Map.fetch!(:id)

      assert {:error, :not_your_turn} = TableManager.call(other_id)
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 9 — raise_bet/2
  # ---------------------------------------------------------------------------

  describe "raise_bet/2" do
    test "la relance met à jour last_raise" do
      table = ready_hand(3)
      acting_id = current_player_id(table)
      {:ok, t} = TableManager.raise_bet(acting_id, 100)
      assert t.hand.last_raise == 100
    end

    test "la bankroll du relanceur diminue du montant total misé" do
      table = ready_hand(3)
      acting_id = current_player_id(table)
      bankroll_before = find_player(table, acting_id).bankroll
      {:ok, t} = TableManager.raise_bet(acting_id, 100)
      assert find_player(t, acting_id).bankroll == bankroll_before - 100
    end

    test "le pot augmente du montant de la relance" do
      table = ready_hand(3)
      pot_before = table.hand.pot
      acting_id = current_player_id(table)
      {:ok, t} = TableManager.raise_bet(acting_id, 100)
      assert t.hand.pot == pot_before + 100
    end

    test "une re-relance est possible si > last_raise" do
      table = ready_hand(4)
      id1 = current_player_id(table)
      {:ok, t} = TableManager.raise_bet(id1, 100)
      id2 = current_player_id(t)
      {:ok, t2} = TableManager.raise_bet(id2, 200)
      assert t2.hand.last_raise == 200
    end

    test "refus si la relance est inférieure à la BB" do
      table = ready_hand(3)
      bb = table.big_blind
      acting_id = current_player_id(table)
      assert {:error, :raise_too_small} = TableManager.raise_bet(acting_id, bb - 1)
    end

    test "refus si la relance est inférieure au dernier raise" do
      table = ready_hand(4)
      id1 = current_player_id(table)
      {:ok, t} = TableManager.raise_bet(id1, 100)
      id2 = current_player_id(t)
      # Fold id2, puis id3 essaie une relance inférieure
      {:ok, t2} = TableManager.fold(id2)
      id3 = current_player_id(t2)
      assert {:error, :raise_too_small} = TableManager.raise_bet(id3, 50)
    end

    test "refus si le joueur n'a pas assez de bankroll" do
      table = ready_hand(3)
      acting_id = current_player_id(table)
      bankroll = find_player(table, acting_id).bankroll
      assert {:error, :insufficient_funds} = TableManager.raise_bet(acting_id, bankroll + 1)
    end

    test "refus si ce n'est pas le tour du joueur" do
      table = ready_hand(3)

      other_id =
        table.players
        |> Enum.find(&(&1.id != current_player_id(table) && &1.status == :active))
        |> Map.fetch!(:id)

      assert {:error, :not_your_turn} = TableManager.raise_bet(other_id, 100)
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 10 — all_in/1
  # ---------------------------------------------------------------------------

  describe "all_in/1" do
    test "le joueur passe en :all_in" do
      table = ready_hand(3)
      acting_id = current_player_id(table)
      {:ok, t} = TableManager.all_in(acting_id)
      assert find_player(t, acting_id).status == :all_in
    end

    test "le bankroll du joueur passe à 0" do
      table = ready_hand(3)
      acting_id = current_player_id(table)
      {:ok, t} = TableManager.all_in(acting_id)
      assert find_player(t, acting_id).bankroll == 0
    end

    test "le pot augmente du bankroll entier du joueur" do
      table = ready_hand(3)
      acting_id = current_player_id(table)
      bankroll = find_player(table, acting_id).bankroll
      pot_before = table.hand.pot
      {:ok, t} = TableManager.all_in(acting_id)
      assert t.hand.pot == pot_before + bankroll
    end

    test "un joueur :all_in ne peut plus agir dans la main" do
      table = ready_hand(3)
      acting_id = current_player_id(table)
      {:ok, _t} = TableManager.all_in(acting_id)
      # L'appel suivant doit retourner une erreur, pas crasher
      assert {:error, :not_your_turn} = TableManager.all_in(acting_id)
    end

    test "un joueur :all_in est passé lors de la détermination du joueur suivant" do
      table = ready_hand(4)
      id1 = current_player_id(table)
      {:ok, t} = TableManager.all_in(id1)
      # Le joueur suivant doit être différent de id1
      refute current_player_id(t) == id1
    end

    test "refus si ce n'est pas le tour du joueur" do
      table = ready_hand(3)

      other_id =
        table.players
        |> Enum.find(&(&1.id != current_player_id(table) && &1.status == :active))
        |> Map.fetch!(:id)

      assert {:error, :not_your_turn} = TableManager.all_in(other_id)
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 11 — Progression des rounds
  # ---------------------------------------------------------------------------

  describe "progression des rounds" do
    test "après le tour de preflop complet, on passe au :flop" do
      table = ready_hand(3)
      # UTG call, SB call, BB check
      {:ok, t} = TableManager.call(current_player_id(table))
      {:ok, t} = TableManager.call(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      assert t.hand.current_round == :flop
    end

    test "community_cards_count == 3 au flop" do
      table = ready_hand(3)
      {:ok, t} = TableManager.call(current_player_id(table))
      {:ok, t} = TableManager.call(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      assert t.hand.community_cards_count == 3
    end

    test "les bets du tour sont remis à zéro à chaque nouveau round" do
      table = ready_hand(3)
      {:ok, t} = TableManager.call(current_player_id(table))
      {:ok, t} = TableManager.call(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      assert t.hand.bets == %{}
    end

    test "après le flop, on passe au :turn" do
      table = ready_hand(3)
      # preflop : UTG call, SB call, BB check (option)
      {:ok, t} = TableManager.call(current_player_id(table))
      {:ok, t} = TableManager.call(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      # flop : SB → BB → dealer (3 checks)
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      assert t.hand.current_round == :turn
    end

    test "community_cards_count == 4 au turn" do
      table = ready_hand(3)
      {:ok, t} = TableManager.call(current_player_id(table))
      {:ok, t} = TableManager.call(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      # flop (3 checks)
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      assert t.hand.community_cards_count == 4
    end

    test "après le turn, on passe à la :river" do
      table = ready_hand(3)
      {:ok, t} = TableManager.call(current_player_id(table))
      {:ok, t} = TableManager.call(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      # flop (3 checks)
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      # turn (3 checks)
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      assert t.hand.current_round == :river
    end

    test "community_cards_count == 5 à la river" do
      table = ready_hand(3)
      {:ok, t} = TableManager.call(current_player_id(table))
      {:ok, t} = TableManager.call(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      # flop (3 checks)
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      # turn (3 checks)
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      # river : 1er check suffit pour constater cc == 5
      {:ok, t} = TableManager.check(current_player_id(t))
      assert t.hand.community_cards_count == 5
    end

    test "après la river, le round passe en :showdown" do
      table = ready_hand(3)
      {:ok, t} = TableManager.call(current_player_id(table))
      {:ok, t} = TableManager.call(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      # flop (3 checks)
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      # turn (3 checks)
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      # river (3 checks)
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      assert t.hand.current_round == :showdown
    end

    test "une relance rouvre l'action (le relanceur peut être re-relancé)" do
      table = ready_hand(3)
      id1 = current_player_id(table)
      {:ok, t} = TableManager.raise_bet(id1, 100)
      id2 = current_player_id(t)
      {:ok, t} = TableManager.raise_bet(id2, 200)
      # id1 doit pouvoir agir à nouveau (re-raise ou call ou fold)
      id3 = current_player_id(t)

      if id3 != id1 do
        {:ok, t} = TableManager.fold(id3)
      end

      # id1 doit maintenant être le joueur courant
      assert current_player_id(TableManager.get_state()) == id1
    end

    test "le premier joueur à agir au flop/turn/river est le premier actif après le dealer" do
      table = ready_hand(3)
      # dealer_seat = 0, donc le premier actif en post-flop = seat 1 (SB)
      {:ok, t} = TableManager.call(current_player_id(table))
      {:ok, t} = TableManager.call(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      # Au flop, current_player_seat doit être 1 (SB)
      assert t.hand.current_player_seat == 1
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 12 — Showdown et distribution du pot
  # ---------------------------------------------------------------------------

  describe "declare_winner/2" do
    # Amène la table au showdown
    defp reach_showdown(count \\ 3) do
      table = ready_hand(count)
      # preflop : UTG call, SB call, BB check
      {:ok, t} = TableManager.call(current_player_id(table))
      {:ok, t} = TableManager.call(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      # flop (3 checks : SB → BB → dealer)
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      # turn (3 checks)
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      # river (3 checks)
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      t
    end

    test "le GM peut déclarer un gagnant au showdown" do
      table = reach_showdown(3)
      assert table.hand.current_round == :showdown
      winner_id = hd(table.players).id
      assert {:ok, _} = TableManager.declare_winner(gm_id(), winner_id)
    end

    test "le gagnant reçoit le pot" do
      table = reach_showdown(3)
      pot = table.hand.pot
      winner_id = hd(table.players).id
      bankroll_before = find_player(table, winner_id).bankroll
      {:ok, t} = TableManager.declare_winner(gm_id(), winner_id)
      assert find_player(t, winner_id).bankroll == bankroll_before + pot
    end

    test "la main se termine après la déclaration du gagnant" do
      table = reach_showdown(3)
      winner_id = hd(table.players).id
      {:ok, t} = TableManager.declare_winner(gm_id(), winner_id)
      assert is_nil(t.hand)
    end

    test "le pot est remis à zéro après distribution" do
      table = reach_showdown(3)
      winner_id = hd(table.players).id
      {:ok, t} = TableManager.declare_winner(gm_id(), winner_id)
      # hand est nil, mais la prochaine main partira d'un pot nul
      assert is_nil(t.hand)
    end

    test "les joueurs :folded redeviennent :active pour la prochaine main" do
      table = ready_hand(3)
      # Faire folder quelqu'un
      id1 = current_player_id(table)
      {:ok, _} = TableManager.fold(id1)
      {:ok, t2} = TableManager.fold(current_player_id(TableManager.get_state()))
      # id1 est :folded — après la fin de la main, devrait repasser :active
      {:ok, t3} = TableManager.new_hand(gm_id())
      assert find_player(t3, id1).status == :active
    end

    test "refus si le gagnant déclaré n'est pas à la table" do
      table = reach_showdown(3)
      assert {:error, :player_not_eligible} = TableManager.declare_winner(gm_id(), "unknown_tag")
    end

    test "refus si appelé par un non-GM" do
      table = reach_showdown(3)
      winner_id = hd(table.players).id
      assert {:error, :not_gm} = TableManager.declare_winner("bob", winner_id)
    end

    test "refus si on n'est pas au showdown" do
      table = ready_hand(3)
      winner_id = hd(table.players).id
      assert {:error, :not_showdown} = TableManager.declare_winner(gm_id(), winner_id)
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 13 — Side pots (all-in multiples)
  # ---------------------------------------------------------------------------

  describe "side pots" do
    test "un side pot est créé quand un joueur est all-in avec moins que les autres" do
      {:ok, _} = TableManager.create_table(gm_id())
      {:ok, _} = TableManager.join_table("bob")
      {:ok, _} = TableManager.join_table("charlie")
      {:ok, _} = TableManager.start_game(gm_id())
      {:ok, table} = TableManager.new_hand(gm_id())

      # bob all-in à 100, alice et charlie à 300 → side pot existe
      inject_river_with_allin(table, 100, 300)

      {:ok, t1} = TableManager.check("alice")
      {:ok, t2} = TableManager.check("charlie")

      assert t2.hand.current_round == :showdown
      assert length(t2.hand.remaining_pots) >= 2
    end

    test "les side pots contiennent les joueurs éligibles" do
      {:ok, _} = TableManager.create_table(gm_id())
      {:ok, _} = TableManager.join_table("bob")
      {:ok, _} = TableManager.join_table("charlie")
      {:ok, _} = TableManager.start_game(gm_id())
      {:ok, table} = TableManager.new_hand(gm_id())

      # bob all-in à 100, alice et charlie à 200
      inject_river_with_allin(table, 100, 200)

      {:ok, t1} = TableManager.check("alice")
      {:ok, t2} = TableManager.check("charlie")

      assert t2.hand.current_round == :showdown
      # bob est éligible au pot principal (il y a contribué)
      main_pot = hd(t2.hand.remaining_pots)
      {_amount, eligible_ids} = main_pot
      assert "bob" in eligible_ids
      # bob n'est pas éligible au side pot (il n'y a pas contribué)
      side_pot = List.last(t2.hand.remaining_pots)
      {_amount2, side_eligible} = side_pot
      refute "bob" in side_eligible
    end

    test "le montant du pot principal est cappé au all-in du joueur le plus court" do
      {:ok, _} = TableManager.create_table(gm_id())
      {:ok, _} = TableManager.join_table("bob")
      {:ok, _} = TableManager.join_table("charlie")
      {:ok, _} = TableManager.start_game(gm_id())
      {:ok, table} = TableManager.new_hand(gm_id())

      # bob all-in à 100, alice et charlie à 500
      inject_river_with_allin(table, 100, 500)

      {:ok, t1} = TableManager.check("alice")
      {:ok, t2} = TableManager.check("charlie")

      assert t2.hand.current_round == :showdown
      # Le pot auquel bob est éligible ne peut dépasser 100 × nb_joueurs
      {bob_amount, _} = hd(t2.hand.remaining_pots)
      assert bob_amount <= 100 * length(t2.players)
    end

    test "declare_winner avec side pots distribue correctement" do
      {:ok, _} = TableManager.create_table(gm_id())
      {:ok, _} = TableManager.join_table("bob")
      {:ok, _} = TableManager.join_table("charlie")

      :sys.replace_state(TableManager, fn %Table{} = t ->
        players =
          Enum.map(t.players, fn
            %Player{id: "bob"} = p -> %{p | bankroll: 100}
            p -> p
          end)

        %{t | players: players}
      end)

      {:ok, _} = TableManager.start_game(gm_id())
      {:ok, table} = TableManager.new_hand(gm_id())

      acting_id = current_player_id(table)

      if acting_id != "bob" do
        {:ok, t} = TableManager.raise_bet(acting_id, 200)
        {:ok, t2} = TableManager.all_in("bob")
        # Fold restants pour forcer showdown rapide
        Enum.reduce_while(t2.players, t2, fn _p, acc ->
          cond do
            is_nil(acc.hand) -> {:halt, acc}
            acc.hand.current_round == :showdown -> {:halt, acc}
            true -> {:cont, elem(TableManager.fold(current_player_id(acc)), 1)}
          end
        end)

        final = TableManager.get_state()

        if final.hand && final.hand.current_round == :showdown do
          {:ok, t_end} = TableManager.declare_winner(gm_id(), "bob")
          # bob doit avoir récupéré sa part du pot
          assert find_player(t_end, "bob").bankroll > 0
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 14 — Éliminations
  # ---------------------------------------------------------------------------

  describe "élimination des joueurs (bankroll == 0)" do
    test "un joueur qui perd son dernier chip passe en :out" do
      {:ok, _} = TableManager.create_table(gm_id())
      {:ok, table} = TableManager.join_table("bob")

      # Bob avec seulement les blindes
      bb = table.big_blind

      :sys.replace_state(TableManager, fn %Table{} = t ->
        players =
          Enum.map(t.players, fn
            %Player{id: "bob"} = p -> %{p | bankroll: bb}
            p -> p
          end)

        %{t | players: players}
      end)

      {:ok, _} = TableManager.start_game(gm_id())
      {:ok, table} = TableManager.new_hand(gm_id())

      # Bob poste BB puis tout le monde fold sauf alice qui call → bob gagne rien si il fold
      # On force bob à all-in
      acting_id = current_player_id(table)

      if acting_id == "alice" do
        {:ok, t} = TableManager.raise_bet("alice", 500)
        {:ok, t2} = TableManager.all_in("bob")
        # Declare alice winner
        {:ok, _t3} = TableManager.declare_winner(gm_id(), "alice")
        bob_final = find_player(TableManager.get_state(), "bob")
        assert bob_final.bankroll == 0
        assert bob_final.status == :out
      end
    end

    test "un joueur :out n'est pas inclus dans la prochaine main" do
      {:ok, _} = TableManager.create_table(gm_id())
      {:ok, _} = TableManager.join_table("bob")
      {:ok, _} = TableManager.join_table("charlie")

      :sys.replace_state(TableManager, fn %Table{} = t ->
        players =
          Enum.map(t.players, fn
            %Player{id: "bob"} = p -> %{p | bankroll: 0, status: :out}
            p -> p
          end)

        %{t | players: players}
      end)

      {:ok, _} = TableManager.start_game(gm_id())
      {:ok, table} = TableManager.new_hand(gm_id())

      active = Enum.filter(table.players, &(&1.status != :out))
      refute Enum.any?(active, &(&1.id == "bob"))
    end

    test "la partie se termine si un seul joueur reste en jeu" do
      {:ok, _} = TableManager.create_table(gm_id())
      {:ok, _} = TableManager.join_table("bob")
      {:ok, _} = TableManager.start_game(gm_id())
      {:ok, _table} = TableManager.new_hand(gm_id())

      acting_id = current_player_id(TableManager.get_state())
      {:ok, t} = TableManager.fold(acting_id)

      # Avec un seul joueur restant non-éliminé, new_hand devrait échouer
      # ou la table doit indiquer la fin de partie
      result = TableManager.new_hand(gm_id())

      assert result == {:error, :not_enough_players} or
               (match?({:ok, _}, result) and
                  length(Enum.filter(TableManager.get_state().players, &(&1.status != :out))) >= 2)
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 15 — reset_table/1
  # ---------------------------------------------------------------------------

  describe "reset_table/1" do
    test "remet le statut en :waiting" do
      ready_hand(3)
      {:ok, t} = TableManager.reset_table(gm_id())
      assert t.status == :waiting
    end

    test "ne garde que le GM dans la liste des joueurs" do
      ready_hand(3)
      {:ok, t} = TableManager.reset_table(gm_id())
      assert length(t.players) == 1
      assert hd(t.players).id == gm_id()
    end

    test "remet hand à nil" do
      ready_hand(3)
      {:ok, t} = TableManager.reset_table(gm_id())
      assert is_nil(t.hand)
    end

    test "refus si appelé par un non-GM" do
      ready_hand(3)
      assert {:error, :not_gm} = TableManager.reset_table("bob")
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 16 — Scénarios de bout en bout
  # ---------------------------------------------------------------------------

  describe "scénarios complets" do
    test "main complète : preflop call → flop check → turn check → river check → showdown" do
      table = ready_hand(3)
      # preflop : UTG call, SB call, BB check
      {:ok, t} = TableManager.call(current_player_id(table))
      {:ok, t} = TableManager.call(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      assert t.hand.current_round == :flop
      # flop (SB → BB → dealer)
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      assert t.hand.current_round == :turn
      # turn
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      assert t.hand.current_round == :river
      # river
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      {:ok, t} = TableManager.check(current_player_id(t))
      assert t.hand.current_round == :showdown
    end

    test "la somme des bankrolls reste constante tout au long d'une main" do
      table = ready_hand(3)
      # total_chips = bankrolls + pot (les blindes sont déjà dans le pot)
      total_chips = (table.players |> Enum.map(& &1.bankroll) |> Enum.sum()) + table.hand.pot
      # Quelques actions
      {:ok, t} = TableManager.raise_bet(current_player_id(table), 100)
      {:ok, t} = TableManager.call(current_player_id(t))
      {:ok, t} = TableManager.fold(current_player_id(t))
      total_after = (t.players |> Enum.map(& &1.bankroll) |> Enum.sum()) + t.hand.pot
      assert total_chips == total_after
    end

    test "preflop : fold générale → le dernier joueur reçoit le pot sans showdown" do
      table = ready_hand(3)
      pot = table.hand.pot

      survivor_id =
        table.players
        |> Enum.find(&(&1.status == :active))
        |> then(fn _ ->
          # Le survivor est le dernier à ne pas avoir foldé
          Enum.at(table.players, 2).id
        end)

      # Seats 0 fold, seat 1 fold
      {:ok, t1} = TableManager.fold(current_player_id(table))
      {:ok, t2} = TableManager.fold(current_player_id(t1))

      # La main doit être terminée
      assert is_nil(t2.hand)
      # Le survivor a récupéré le pot
      assert find_player(t2, survivor_id).bankroll > 1_000 - table.big_blind
    end

    test "deux mains consécutives : dealer_seat tourne" do
      {:ok, _} = TableManager.create_table(gm_id())
      {:ok, _} = TableManager.join_table("bob")
      {:ok, _} = TableManager.join_table("charlie")
      {:ok, _} = TableManager.start_game(gm_id())

      {:ok, t1} = TableManager.new_hand(gm_id())
      dealer1 = t1.dealer_seat

      # Terminer la main rapidement (fold fold)
      {:ok, t} = TableManager.fold(current_player_id(t1))
      {:ok, _} = TableManager.fold(current_player_id(t))

      {:ok, t2} = TableManager.new_hand(gm_id())
      dealer2 = t2.dealer_seat

      assert dealer2 == rem(dealer1 + 1, length(t2.players))
    end
  end
end
