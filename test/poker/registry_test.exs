defmodule RegistryTest do
  use Poker.DataCase, async: false

  alias Poker.Players.Registry

  setup do
    start_supervised!({Registry, []})
    Ecto.Adapters.SQL.Sandbox.allow(Poker.Repo, self(), Registry)

    :ok
  end

  # ----------------------------
  # Enregistrement des joueurs
  # ----------------------------

  describe "Ajout de joueurs qui n'existent pas dans la base" do
    test "registers a missing player and stores it in the registry" do
      assert {:ok, player} = Registry.register("tag-123", "Alice", 10000)
      assert player.tag_id == "tag-123"
      assert player.name == "Alice"
      assert player.bankroll == 10000

      assert {:ok, ^player} = Registry.lookup("tag-123")
      {:ok, all_players} = Registry.all()
      assert Enum.any?(all_players, fn p -> p.tag_id == "tag-123" end)
    end

    test "returns error when registering an already registered tag" do
      assert {:ok, _player} = Registry.register("tag-1234", "Alice", 10000)
      assert {:error, :already_registered} = Registry.register("tag-1234", "Bob", 5000)
    end
  end
end
