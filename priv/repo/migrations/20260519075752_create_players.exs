defmodule Poker.Repo.Migrations.CreatePlayers do
  use Ecto.Migration

  def change do
    create table(:players) do
      add :tag_id, :string, null: false
      add :name, :string, null: false
      add :bankroll, :integer, null: false
      add :status,   :string, default: "active"
      timestamps()
    end

    create unique_index(:players, [:tag_id])
  
  end
end
