defmodule Poker.TableManagerTest do
  use Poker.DataCase, async: false

  alias Poker.TableManager
  alias Poker.TableManager.{Table, Player, Hand}
  alias Poker.Players.Registry

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------
  setup do
    start_supervised!({Registry, []})
    start_supervised!({TableManager, []})

    Ecto.Adapters.SQL.Sandbox.allow(Poker.Repo, self(), TableManager)
    Ecto.Adapters.SQL.Sandbox.allow(Poker.Repo, self(), Registry)


    #Enregistrer des joueurs
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

    test "le dealer_seat initial est 0" do
      {:ok, table} = create_table()
      assert table.dealer_seat == 0
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

    test "le GM a le seat 0" do
      {:ok, table} = create_table()
      [gm_player] = table.players
      assert gm_player.seat == 0
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

    test "les seats sont attribués en séquence (0, 1, 2...)" do
      {:ok, table} = create_table()
      {:ok, t2} = TableManager.join_table("bob")
      {:ok, t3} = TableManager.join_table("charlie")

      seats = Enum.map(t3.players, & &1.seat)
      assert seats == [0, 1, 2]
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

    test "le dealer_seat est 0 au premier démarrage" do
      table = table_with_players(2)
      {:ok, started} = TableManager.start_game("alice")
      assert started.dealer_seat == 0
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
      assert Map.has_key?(player, :seat)
      assert Map.has_key?(player, :status)
    end

    test "Hand est nil tant que la partie n'a pas commencé" do
      table = table_with_players(3)
      assert is_nil(table.hand)
    end
  end
end
