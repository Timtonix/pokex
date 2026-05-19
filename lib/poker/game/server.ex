defmodule Poker.Game.Server do
  use GenServer

  defstruct [
  phase: :waiting,
  players: [],              # ordre des joueurs à la table
  dealer_index: 0,          # position du dealer, tourne à chaque main
  active_player: nil,       # tag_id dont c'est le tour
  folded: [],               # tag_id des joueurs couchés
  all_in: [],               # tag_id des joueurs all-in
  pot: 0,
  side_pots: [],            # [{amount, [eligible_tag_ids]}]
  bets: %{},                # mises du tour courant (remis à 0 à chaque phase)
  current_bet: 0,           # mise maximale courante du tour
  small_blind: 50,          # configurable par le GM
  big_blind: 100,
  hand_number: 0,
  gm_unlocked: false,
  gm_unlocked_at: nil
]

  # Fonctions d'API publique
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)
  end

  @doc "Renvoie le state de la partie"
  def state() do
    GenServer.call(__MODULE__, :state)
  end

  @doc "Un joueur scan son tag"
  def player_scan(tag_id) do
    GenServer.call(__MODULE__, {:player_scan, tag_id})
  end

  @doc "Lance la partie"
  def start_hand() do
    GenServer.call(__MODULE__, :start_hand)
  end

  @doc "Le maitre du jeu scan son badge"
  def gm_scan() do
    GenServer.cast(__MODULE__, :gm_scan)
  end

  @doc "effectue l'action d'un joueur"
  def player_action(tag_id, action) when is_atom(action) do
    GenServer.call(__MODULE__, {action, tag_id})
  end



  # Callbacks GenServer
  @impl true
  def init(_) do
    state = %__MODULE__{}
    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:player_scan, tag_id}, _from, state) do
    case Poker.Players.Registry.lookup(tag_id) do
      nil ->
        {:reply, {:error, :unknown_player}, state}

      _player ->
        if tag_id in state.players do
          # Player is already seated, so remove them (toggle)
          new_players = List.delete(state.players, tag_id)
          {:reply, {:ok, :left}, %{state | players: new_players}}
        else
          # Add player to seated list
          new_players = state.players ++ [tag_id]
          {:reply, {:ok, :seated}, %{state | players: new_players}}
        end
    end
  end

  @impl true
  def handle_call(:start_hand, _from, state) do
    if state.gm_unlocked == true do
      if length(state.players) >= 2 do
        {:reply, {:ok, :hand_started}, %{state | phase: :pre_flop}}
      else
        {:reply, {:error, :not_enough_players}, state}
      end
    else
      {:reply, {:error, :gm_not_unlocked}, state}
    end
  end

  @impl true
  def handle_call({:fold, tag_id}, _from, state) do
    # vérifier si c'est son tour
    if Enum.at(state.players, state.hand_number) == tag_id do
      {:reply, {:ok, :folded}, %{state |
      folded: state.folded ++ [tag_id],
      players: state.players -- [tag_id],
      hand_number: state.hand_number + 1
       }}
    end
  end


  @impl true
  def handle_cast(:gm_scan, state) do
    {:noreply, %{state | gm_unlocked: true}}
  end

end
