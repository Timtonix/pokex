defmodule Poker.Players.Player do
  use Ecto.Schema
  import Ecto.Changeset

  schema "players" do
    field :tag_id,   :string
    field :name,     :string
    field :bankroll, :integer
    field :status,   :string, default: "active"
    timestamps()
  end

  def changeset(player, attrs) do
    player
    |> cast(attrs, [:tag_id, :name, :bankroll, :status])
    |> validate_required([:tag_id, :name, :bankroll])
    |> validate_number(:bankroll, greater_than_or_equal_to: 0)
    |> unique_constraint(:tag_id)
  end
end
