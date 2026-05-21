defmodule Poker.TableManagerTest do
  use ExUnit.Case, async: true

  alias Poker.TableManager
  alias Poker.TableManager.{Table, Player, Hand}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp gm_id, do: "TAG-GM-001"
  defp player_ids, do: ["TAG-P-002", "TAG-P-003", "TAG-P-004"]

  defp create_table do
    TableManager.create_table(gm_id())
  end

  defp table_with_players(count \\ 2) do
    {:ok, table} = create_table()

    names = ["Bob", "Carol", "Dave"]
    player_ids = Enum.take(player_ids(), count - 1)

    Enum.reduce(Enum.zip(player_ids, names), table, fn {id, name}, acc ->
      {:ok, t} = TableManager.join_table(acc, id, name)
      t
    end)
  end

  # ---------------------------------------------------------------------------
  # BLOC 1 — Création de table
  # ---------------------------------------------------------------------------

  describe "create_table/2" do
    test "retourne {:ok, %Table{}} avec les valeurs par défaut" do
      assert {:ok, %Table{} = table} = create_table()
    end

    test "le table_id est unique et non nil" do
      {:ok, t1} = create_table()
      {:ok, t2} = create_table()

      refute is_nil(t1.table_id)
      refute is_nil(t2.table_id)
      assert t1.table_id != t2.table_id
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

    test "le joueur GM a le stack initial par défaut (1000)" do
      {:ok, table} = create_table()
      [gm_player] = table.players
      assert gm_player.stack == 1000
    end

    test "le joueur GM a le statut :active" do
      {:ok, table} = create_table()
      [gm_player] = table.players
      assert gm_player.status == :active
    end

    test "refus si le tag GM est une chaîne vide" do
      assert {:error, :invalid_tag} = TableManager.create_table("", "Alice")
    end

    test "refus si le pseudo est une chaîne vide" do
      assert {:error, :invalid_name} = TableManager.create_table(gm_id(), "")
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 2 — Rejoindre la table
  # ---------------------------------------------------------------------------

  describe "join_table/3" do
    test "un joueur peut rejoindre une table en :waiting" do
      {:ok, table} = create_table()
      assert {:ok, updated_table} = TableManager.join_table(table, "TAG-P-002", "Bob")
      assert length(updated_table.players) == 2
    end

    test "le joueur ajouté a les bonnes données" do
      {:ok, table} = create_table()
      {:ok, updated_table} = TableManager.join_table(table, "TAG-P-002", "Bob")

      bob = Enum.find(updated_table.players, &(&1.id == "TAG-P-002"))
      assert bob.name == "Bob"
      assert bob.stack == 1000
      assert bob.status == :active
    end

    test "les seats sont attribués en séquence (0, 1, 2...)" do
      {:ok, table} = create_table()
      {:ok, t2} = TableManager.join_table(table, "TAG-P-002", "Bob")
      {:ok, t3} = TableManager.join_table(t2, "TAG-P-003", "Carol")

      seats = Enum.map(t3.players, & &1.seat)
      assert seats == [0, 1, 2]
    end

    test "l'ordre des joueurs reflète l'ordre de scan" do
      {:ok, table} = create_table()
      {:ok, t2} = TableManager.join_table(table, "TAG-P-002", "Bob")
      {:ok, t3} = TableManager.join_table(t2, "TAG-P-003", "Carol")

      ids = Enum.map(t3.players, & &1.id)
      assert ids == [gm_id(), "TAG-P-002", "TAG-P-003"]
    end

    test "refus si la table est en :playing" do
      {:ok, table} = create_table()
      playing_table = %{table | status: :playing}

      assert {:error, :game_already_started} =
               TableManager.join_table(playing_table, "TAG-P-002", "Bob")
    end

    test "refus si le tag est déjà enregistré" do
      {:ok, table} = create_table()
      {:ok, updated_table} = TableManager.join_table(table, "TAG-P-002", "Bob")

      assert {:error, :player_already_registered} =
               TableManager.join_table(updated_table, "TAG-P-002", "Bob Bis")
    end

    test "refus si on dépasse max_players (6)" do
      {:ok, table} = create_table()

      full_table =
        Enum.reduce(1..5, table, fn i, acc ->
          {:ok, t} = TableManager.join_table(acc, "TAG-P-00#{i + 1}", "Player#{i}")
          t
        end)

      assert {:error, :table_full} =
               TableManager.join_table(full_table, "TAG-P-007", "Trop")
    end

    test "refus si le tag est une chaîne vide" do
      {:ok, table} = create_table()
      assert {:error, :invalid_tag} = TableManager.join_table(table, "", "Bob")
    end

    test "refus si le pseudo est une chaîne vide" do
      {:ok, table} = create_table()
      assert {:error, :invalid_name} = TableManager.join_table(table, "TAG-P-002", "")
    end

    test "6 joueurs peuvent rejoindre sans erreur (limite max)" do
      {:ok, table} = create_table()

      result =
        Enum.reduce_while(1..5, table, fn i, acc ->
          case TableManager.join_table(acc, "TAG-P-00#{i + 1}", "Player#{i}") do
            {:ok, t} -> {:cont, t}
            {:error, _} = err -> {:halt, err}
          end
        end)

      assert %Table{} = result
      assert length(result.players) == 6
    end
  end

  # ---------------------------------------------------------------------------
  # BLOC 3 — Démarrage de la partie (prérequis avant la logique de jeu)
  # ---------------------------------------------------------------------------

  describe "start_game/1" do
    test "passage en :playing si min 2 joueurs" do
      table = table_with_players(2)
      assert {:ok, %Table{status: :playing}} = TableManager.start_game(table)
    end

    test "refus si moins de 2 joueurs" do
      {:ok, table} = create_table()
      assert {:error, :not_enough_players} = TableManager.start_game(table)
    end

    test "refus si la partie est déjà en cours" do
      table = table_with_players(2)
      {:ok, playing_table} = TableManager.start_game(table)
      assert {:error, :game_already_started} = TableManager.start_game(playing_table)
    end

    test "seul le GM peut démarrer — refus si appelé par un autre joueur" do
      table = table_with_players(2)

      assert {:error, :not_gm} =
               TableManager.start_game(table, caller_id: "TAG-P-002")
    end

    test "le dealer_seat est 0 au premier démarrage" do
      table = table_with_players(2)
      {:ok, started} = TableManager.start_game(table)
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
      assert Map.has_key?(player, :stack)
      assert Map.has_key?(player, :seat)
      assert Map.has_key?(player, :status)
    end

    test "Hand est nil tant que la partie n'a pas commencé" do
      table = table_with_players(3)
      assert is_nil(table.hand)
    end
  end
end
