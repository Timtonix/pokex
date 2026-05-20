defmodule RegistryTest do
use Poker.DataCase, async: false

  alias Poker.Players.Registry

  def setup do
    start_supervised!({Registry, []})
    Ecto.Adapters.SQL.Sandbox.allow(Poker.Repo, self(), Registry)

    :ok
  end

  # ----------------------------
  # Enregistrement des joueurs
  # ----------------------------

  describe "Ajout de joueurs qui n'existent pas dans la base" do
    def test "Scannage de tag qui n'est pas dans la base" do
      Registry.register("azertycaca", "Timtonix", 10000)
    end
  end

end
