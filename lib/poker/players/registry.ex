defmodule Poker.Players.Registry do
  use GenServer
  alias Poker.{Repo, Players.Player}

  # ---------------------------------------------------------------------------
  # API publique
  # ---------------------------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Enregistre un nouveau joueur avec son tag NFC"
  def register(tag_id, name, bankroll) do
    GenServer.call(__MODULE__, {:register, tag_id, name, bankroll})
  end

  @doc "Retourne le joueur associé au tag, ou nil"
  def lookup(tag_id) do
    GenServer.call(__MODULE__, {:lookup, tag_id})
  end

  @doc "Retourne tous les joueurs"
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @doc "Ajoute ou retire des jetons (amount peut être négatif)"
  def update_bankroll(tag_id, amount) do
    GenServer.call(__MODULE__, {:update_bankroll, tag_id, amount})
  end

  @doc "Change le statut d'un joueur (:active | :away | :out)"
  def set_status(tag_id, status) do
    GenServer.call(__MODULE__, {:set_status, tag_id, status})
  end

  # ---------------------------------------------------------------------------
  # Callbacks GenServer
  # ---------------------------------------------------------------------------


  # Démarrage : charge tout depuis SQLite en mémoire
  @impl true
  def init(_) do
    players = Repo.all(Player) # Variable utilisée une seule fois
    state = Map.new(players, fn p -> {p.tag_id, p} end) # Variable
    {:ok, state}
  end

  @impl true
  def handle_call(:all, _from, state) do
    {:reply, Map.values(state), state}
  end

  @doc """
  Enregistre un nouveau joueur
  1. On vérifie qu'il n'existe pas déja dans notre `state`
  2. On crée le changement en mémoire (nouveau joueur)
  3. On essaie de le mettre en DB
  4. On update le state
  """
  @impl true
  def handle_call({:register, tag_id, name, bankroll}, _from, state) do
    case Map.get(state, tag_id) do
      nil ->
        changeset = Player.changeset(%Player{}, %{
          tag_id: tag_id,
          name: name,
          bankroll: bankroll
        })

        case Repo.insert(changeset) do
          {:ok, player} ->
            {:reply, {:ok, player}, Map.put(state, tag_id, player)}

          {:error, changeset} ->
            {:reply, {:error, changeset}, state}
        end

        _existing -> {:reply, {:error, :already_registered}, state}

    end
  end


  @impl true
  def handle_call({:lookup, tag_id}, _from, state) do
    {:reply, Map.get(state, tag_id), state}
  end

  # Écriture : mémoire + SQLite
  @impl true
  def handle_call({:update_bankroll, tag_id, amount}, _from, state) do
    case Map.get(state, tag_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      player ->
        new_bankroll = player.bankroll + amount

        if new_bankroll < 0 do
          {:reply, {:error, :insufficient_funds}, state}
        else
          case player |> Player.changeset(%{bankroll: new_bankroll}) |> Repo.update() do
            {:ok, updated} ->
              {:reply, {:ok, updated}, Map.put(state, tag_id, updated)}

            {:error, changeset} ->
              {:reply, {:error, changeset}, state}
          end
        end
    end

  end

  @impl true
  def handle_call({:set_status, tag_id, status}, _from, state) do
    case Map.get(state, tag_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      player ->
        case Player.changeset(player, %{status: to_string(status)}) |> Repo.update() do
          {:ok, updated} ->
            {:reply, {:ok, updated}, Map.put(state, tag_id, updated)}

          {:error, changeset} ->
            {:reply, {:error, changeset}, state}
        end
      end
  end
end
