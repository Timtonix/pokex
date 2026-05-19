defmodule Poker.Game.ServerTest do
  use Poker.DataCase, async: false

  alias Poker.Game.Server
  alias Poker.Players.Registry

  # ---------------------------------------------------------------------------
  # Setup : démarre un Registry et un Game.Server isolés pour chaque test
  # ---------------------------------------------------------------------------

  setup do

    # On démarre des processus isolés pour chaque test
    start_supervised!({Registry, []})
    start_supervised!({Server, []})

    # On autorise à utiliser la sandbox SQL
    Ecto.Adapters.SQL.Sandbox.allow(Poker.Repo, self(), Registry)
    Ecto.Adapters.SQL.Sandbox.allow(Poker.Repo, self(), Server)

    # Joueurs de base disponibles pour les tests
    Registry.register("alice", "Alice", 10_000)
    Registry.register("bob", "Bob", 10_000)
    Registry.register("charlie", "Charlie", 10_000)
    Registry.register("diana", "Diana", 10_000)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Phase :waiting — gestion de la table
  # ---------------------------------------------------------------------------

  describe "phase :waiting — joueurs qui s'assoient" do
    test "un joueur connu peut s'asseoir en scannant son tag" do
      assert {:ok, :seated} = Server.player_scan("alice")
      assert "alice" in Server.state().players
    end

    test "un joueur inconnu ne peut pas s'asseoir" do
      assert {:error, :unknown_player} = Server.player_scan("tag-inconnu")
    end

    test "scanner deux fois toggle la présence — le joueur se lève" do
      Server.player_scan("alice")
      assert {:ok, :left} = Server.player_scan("alice")
      refute "alice" in Server.state().players
    end

    test "plusieurs joueurs peuvent s'asseoir" do
      Server.player_scan("alice")
      Server.player_scan("bob")
      Server.player_scan("charlie")
      assert length(Server.state().players) == 3
    end

    test "l'ordre d'arrivée est préservé" do
      Server.player_scan("charlie")
      Server.player_scan("alice")
      Server.player_scan("bob")
      assert Server.state().players == ["charlie", "alice", "bob"]
    end
  end

  # ---------------------------------------------------------------------------
  # Démarrage de main
  # ---------------------------------------------------------------------------

  describe "start_hand/0" do
    test "impossible sans scan GM" do
      seat_players(["alice", "bob"])
      assert {:error, :gm_not_unlocked} = Server.start_hand()
    end

    test "impossible avec moins de 2 joueurs" do
      Server.player_scan("alice")
      Server.gm_scan()
      assert {:error, :not_enough_players} = Server.start_hand()
    end

    test "démarre correctement avec 2 joueurs et GM scanné" do
      seat_players(["alice", "bob"])
      Server.gm_scan()
      assert {:ok, :hand_started} = Server.start_hand()
      assert Server.state().phase == :pre_flop
    end

    test "le numéro de main incrémente à chaque nouvelle main" do
      assert Server.state().hand_number == 0
      play_one_hand(["alice", "bob"])
      assert Server.state().hand_number == 1
    end

    test "les blindes sont débitées automatiquement au démarrage" do
      seat_players(["alice", "bob", "charlie"])
      Server.gm_scan()
      Server.start_hand()

      state = Server.state()
      # SB = bob (index 1), BB = charlie (index 2)
      assert Map.get(state.bets, "bob") == state.small_blind
      assert Map.get(state.bets, "charlie") == state.big_blind
      assert state.pot == state.small_blind + state.big_blind
    end

    test "les bankrolls sont débitées des blindes" do
      seat_players(["alice", "bob", "charlie"])
      Server.gm_scan()
      Server.start_hand()

      bob = Registry.lookup("bob")
      charlie = Registry.lookup("charlie")
      assert bob.bankroll == 10_000 - Server.state().small_blind
      assert charlie.bankroll == 10_000 - Server.state().big_blind
    end

    test "le dealer_index avance à chaque main" do
      play_one_hand(["alice", "bob"])
      assert Server.state().dealer_index == 1
      play_one_hand(["alice", "bob"])
      assert Server.state().dealer_index == 0
    end

    test "le verrou GM est consommé après start_hand" do
      seat_players(["alice", "bob"])
      Server.gm_scan()
      Server.start_hand()
      assert Server.state().gm_unlocked == false
    end
  end

  # ---------------------------------------------------------------------------
  # Tour de parole — pre_flop
  # ---------------------------------------------------------------------------

  describe "tour de parole au pre_flop" do
    setup :start_hand_with_three_players

    test "l'ordre de parole commence à UTG (après BB)" do
      state = Server.state()
      # players: [alice, bob, charlie] → dealer=alice, sb=bob, bb=charlie, utg=alice
      assert state.active_player == "alice"
    end

    test "un joueur peut scanner pour confirmer son tour" do
      assert {:ok, :your_turn} = Server.player_scan("alice")
    end

    test "scanner quand ce n'est pas son tour retourne une erreur" do
      assert {:error, :not_your_turn} = Server.player_scan("bob")
    end

    test "un joueur peut call" do
      assert {:ok, _} = Server.player_action("alice", :call)
    end

    test "un joueur peut fold" do
      assert {:ok, _} = Server.player_action("alice", :fold)
      assert "alice" in Server.state().folded
    end

    test "un joueur peut raise" do
      assert {:ok, _} = Server.player_action("alice", {:raise, 300})
    end

    test "un joueur peut check si personne n'a misé" do
      # Au pre_flop, BB a déjà misé donc check impossible pour alice
      assert {:error, :must_call_or_raise} = Server.player_action("alice", :check)
    end

    test "agir quand ce n'est pas son tour est refusé" do
      assert {:error, :not_your_turn} = Server.player_action("bob", :call)
    end

    test "fold retire le joueur des actifs" do
      Server.player_action("alice", :fold)
      refute "alice" in active_players()
    end

    test "après une action, le tour passe au joueur suivant" do
      Server.player_action("alice", :call)
      assert Server.state().active_player == "bob"
    end

    test "raise oblige les autres joueurs à re-agir" do
      Server.player_action("alice", {:raise, 300})
      # bob et charlie doivent re-parler
      state = Server.state()
      assert state.current_bet == 300
    end
  end

  # ---------------------------------------------------------------------------
  # Transitions de phase
  # ---------------------------------------------------------------------------

  describe "transitions de phase" do
    setup :start_hand_with_three_players

    test "impossible de passer au flop sans scan GM" do
      complete_betting_round(["alice", "bob", "charlie"])
      assert {:error, :gm_not_unlocked} = Server.next_phase()
    end

    test "passe en :flop après le tour pre_flop" do
      complete_betting_round(["alice", "bob", "charlie"])
      Server.gm_scan()
      assert {:ok, :flop} = Server.next_phase()
      assert Server.state().phase == :flop
    end

    test "passe en :turn après le flop" do
      complete_betting_round(["alice", "bob", "charlie"])
      Server.gm_scan()
      Server.next_phase()
      complete_betting_round(["bob", "charlie", "alice"])
      Server.gm_scan()
      assert {:ok, :turn} = Server.next_phase()
    end

    test "passe en :river après la turn" do
      go_to_phase(:river, ["alice", "bob", "charlie"])
      assert Server.state().phase == :river
    end

    test "passe en :showdown après la river" do
      go_to_phase(:showdown, ["alice", "bob", "charlie"])
      assert Server.state().phase == :showdown
    end

    test "les mises sont remises à zéro à chaque nouvelle phase" do
      Server.player_action("alice", {:raise, 200})
      complete_betting_round(["bob", "charlie"])
      Server.gm_scan()
      Server.next_phase()
      assert Server.state().bets == %{}
      assert Server.state().current_bet == 0
    end

    test "le pot s'accumule entre les phases" do
      pot_before = Server.state().pot
      Server.player_action("alice", :call)
      Server.player_action("bob", :call)
      Server.player_action("charlie", :check)
      Server.gm_scan()
      Server.next_phase()
      assert Server.state().pot > pot_before
    end

    test "impossible de sauter une phase" do
      # On ne peut pas passer de pre_flop à turn directement
      assert {:error, :wrong_phase} = Server.award_pot("alice")
    end
  end

  # ---------------------------------------------------------------------------
  # Fin de main automatique
  # ---------------------------------------------------------------------------

  describe "fin de main automatique" do
    setup :start_hand_with_three_players

    test "si tous foldent sauf un, le pot est attribué automatiquement" do
      Server.player_action("alice", :fold)
      Server.player_action("bob", :fold)
      # charlie gagne automatiquement
      state = Server.state()
      assert state.phase == :waiting
      charlie = Registry.lookup("charlie")
      assert charlie.bankroll > 10_000 - state.big_blind
    end

    test "le gagnant automatique est le seul joueur non foldé" do
      Server.player_action("alice", :fold)
      Server.player_action("bob", :fold)
      assert Server.state().last_winner == "charlie"
    end
  end

  # ---------------------------------------------------------------------------
  # All-in et side pots
  # ---------------------------------------------------------------------------

  describe "all-in" do
    test "un joueur peut aller all-in" do
      Registry.register("short", "Short Stack", 200)
      seat_players(["alice", "short", "bob"])
      Server.gm_scan()
      Server.start_hand()

      assert {:ok, _} = Server.player_action("alice", {:raise, 500})
      assert {:ok, _} = Server.player_action("short", :all_in)
      assert "short" in Server.state().all_in
    end

    test "all-in avec moins que la mise courante crée un side pot" do
      Registry.register("short", "Short Stack", 200)
      seat_players(["alice", "short", "bob"])
      Server.gm_scan()
      Server.start_hand()

      Server.player_action("alice", {:raise, 500})
      Server.player_action("short", :all_in)

      state = Server.state()
      assert length(state.side_pots) > 0
    end

    test "un joueur all-in ne peut plus agir" do
      Registry.register("short", "Short Stack", 200)
      seat_players(["alice", "short", "bob"])
      Server.gm_scan()
      Server.start_hand()

      Server.player_action("alice", {:raise, 500})
      Server.player_action("short", :all_in)

      # short ne doit plus être dans les joueurs actifs
      refute "short" in active_players()
    end

    test "si tous sont all-in, on passe directement au showdown" do
      seat_players(["alice", "bob"])
      Server.gm_scan()
      Server.start_hand()

      Server.player_action("alice", :all_in)
      Server.player_action("bob", :all_in)

      assert Server.state().phase == :showdown
    end
  end

  # ---------------------------------------------------------------------------
  # Showdown et payout
  # ---------------------------------------------------------------------------

  describe "showdown et payout" do
    setup :go_to_showdown

    test "le GM peut désigner un gagnant" do
      Server.gm_scan()
      assert {:ok, :pot_awarded} = Server.award_pot("alice")
    end

    test "désigner un gagnant sans scan GM est refusé" do
      assert {:error, :gm_not_unlocked} = Server.award_pot("alice")
    end

    test "désigner un joueur foldé est refusé" do
      # charlie a foldé dans go_to_showdown
      Server.gm_scan()
      assert {:error, :player_folded} = Server.award_pot("charlie")
    end

    test "désigner un joueur absent de la table est refusé" do
      Server.gm_scan()
      assert {:error, :unknown_winner} = Server.award_pot("diana")
    end

    test "le pot est crédité à la bankroll du gagnant" do
      pot = Server.state().pot
      Server.gm_scan()
      Server.award_pot("alice")
      alice = Registry.lookup("alice")
      assert alice.bankroll == 10_000 + pot - Map.get(Server.state().last_bets, "alice", 0)
    end

    test "la partie repasse en :waiting après le payout" do
      Server.gm_scan()
      Server.award_pot("alice")
      assert Server.state().phase == :waiting
    end

    test "le pot est remis à zéro après le payout" do
      Server.gm_scan()
      Server.award_pot("alice")
      assert Server.state().pot == 0
    end

    test "split pot entre deux gagnants" do
      pot = Server.state().pot
      Server.gm_scan()
      assert {:ok, :pot_split} = Server.award_pot(["alice", "bob"])
      alice = Registry.lookup("alice")
      bob = Registry.lookup("bob")
      assert alice.bankroll + bob.bankroll == 20_000 + pot
    end
  end

  # ---------------------------------------------------------------------------
  # Verrou GM
  # ---------------------------------------------------------------------------

  describe "verrou GM" do
    test "le verrou expire après le TTL" do
      seat_players(["alice", "bob"])
      Server.gm_scan()

      # Simule l'expiration en forçant un timestamp dépassé
      :sys.replace_state(Server, fn state ->
        %{state | gm_unlocked_at: System.system_time(:second) - 61}
      end)

      assert {:error, :gm_lock_expired} = Server.start_hand()
    end

    test "scanner à nouveau renouvelle le verrou" do
      seat_players(["alice", "bob"])
      Server.gm_scan()

      :sys.replace_state(Server, fn state ->
        %{state | gm_unlocked_at: System.system_time(:second) - 61}
      end)

      Server.gm_scan()
      assert {:ok, :hand_started} = Server.start_hand()
    end
  end

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  describe "configuration des blindes" do
    test "le GM peut changer les blindes entre les mains" do
      Server.gm_scan()
      assert {:ok, _} = Server.set_blinds(25, 50)
      assert Server.state().small_blind == 25
      assert Server.state().big_blind == 50
    end

    test "impossible de changer les blindes pendant une main" do
      seat_players(["alice", "bob"])
      Server.gm_scan()
      Server.start_hand()
      Server.gm_scan()
      assert {:error, :hand_in_progress} = Server.set_blinds(25, 50)
    end

    test "la big blind doit être supérieure à la small blind" do
      Server.gm_scan()
      assert {:error, :invalid_blinds} = Server.set_blinds(100, 50)
    end
  end

  # ---------------------------------------------------------------------------
  # Actions GM spéciales
  # ---------------------------------------------------------------------------

  describe "actions GM" do
    setup :start_hand_with_three_players

    test "le GM peut forcer un fold sur un joueur AFK" do
      Server.gm_scan()
      assert {:ok, _} = Server.force_fold("alice")
      assert "alice" in Server.state().folded
    end

    test "le GM peut annuler la dernière action" do
      bankroll_before = Registry.lookup("alice").bankroll
      Server.player_action("alice", {:call, 100})
      Server.gm_scan()
      assert {:ok, _} = Server.undo_last_action()
      assert Registry.lookup("alice").bankroll == bankroll_before
    end

    test "le GM peut ajouter des jetons à un joueur en dehors d'une main" do
      # Impossible pendant une main
      Server.gm_scan()
      assert {:error, :hand_in_progress} = Server.add_chips("alice", 5_000)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers privés
  # ---------------------------------------------------------------------------

  defp seat_players(tag_ids) do
    Enum.each(tag_ids, &Server.player_scan/1)
  end

  defp active_players do
    state = Server.state()
    state.players -- (state.folded ++ state.all_in)
  end

  defp complete_betting_round(player_order) do
    Enum.each(player_order, fn tag_id ->
      Server.player_action(tag_id, :check)
    end)
  end

  defp start_hand_with_three_players(_context) do
    seat_players(["alice", "bob", "charlie"])
    Server.gm_scan()
    Server.start_hand()
    :ok
  end

  defp go_to_showdown(_context) do
    seat_players(["alice", "bob", "charlie"])
    Server.gm_scan()
    Server.start_hand()
    # charlie fold, alice et bob vont jusqu'au showdown
    Server.player_action("charlie", :fold)
    complete_betting_round(["alice", "bob"])
    Server.gm_scan()
    Server.next_phase() # flop
    complete_betting_round(["alice", "bob"])
    Server.gm_scan()
    Server.next_phase() # turn
    complete_betting_round(["alice", "bob"])
    Server.gm_scan()
    Server.next_phase() # river
    complete_betting_round(["alice", "bob"])
    Server.gm_scan()
    Server.next_phase() # showdown
    :ok
  end

  defp go_to_phase(target_phase, players) do
    seat_players(players)
    Server.gm_scan()
    Server.start_hand()

    phases = [:flop, :turn, :river, :showdown]
    Enum.reduce_while(phases, nil, fn phase, _acc ->
      complete_betting_round(players -- Server.state().folded)
      Server.gm_scan()
      Server.next_phase()
      if phase == target_phase, do: {:halt, phase}, else: {:cont, phase}
    end)
  end

  defp play_one_hand(players) do
    seat_players(players)
    Server.gm_scan()
    Server.start_hand()
    # Tous call puis fold jusqu'au showdown
    hd(players) |> Server.player_action(:fold)
    # Le deuxième gagne automatiquement
  end
end
