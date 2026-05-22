defmodule PokerWeb.TableLive do
  use PokerWeb, :live_view

  alias Poker.Players.Registry
  alias Poker.TableManager
  alias Poker.TableManager.Table

  @topic "table"

  # ---------------------------------------------------------------------------
  # Mount
  # /table?tag=XXX  (tag optionnel — spectateur si absent)
  #
  # Trois rôles possibles :
  #   :gm         → le tag est celui du GM de la table
  #   :player     → le tag est un joueur inscrit à la table
  #   :spectator  → pas de tag, ou tag non reconnu
  # ---------------------------------------------------------------------------

  @impl true
  def mount(params, _session, socket) do
    tag_id = Map.get(params, "tag")

    # Abonnement PubSub — tous les téléphones reçoivent les mises à jour
    if connected?(socket), do: Phoenix.PubSub.subscribe(Poker.PubSub, @topic)

    table = TableManager.get_state()
    role = determine_role(tag_id, table)
    player = get_player_from_tag(tag_id)

    socket =
      socket
      |> assign(:tag_id, tag_id)
      |> assign(:role, role)
      |> assign(:player, player)
      |> assign(:table, table)

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Gestion des mises à jour PubSub
  # Le GenServer broadcast {:table_updated, %Table{}} à chaque changement
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:table_updated, table}, socket) do
    # Recalcule le rôle au cas où la table vient d'être créée
    role = determine_role(socket.assigns.tag_id, table)

    {:noreply,
     socket
     |> assign(:table, table)
     |> assign(:role, role)}
  end

  # ---------------------------------------------------------------------------
  # Events GM
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("start_game", _params, %{assigns: %{role: :gm, tag_id: tag_id}} = socket) do
    case TableManager.start_game(tag_id) do
      {:ok, _table} -> {:noreply, socket}
      {:error, reason} -> {:noreply, assign(socket, :error, format_error(reason))}
    end
  end

  def handle_event("new_hand", _params, %{assigns: %{role: :gm, tag_id: tag_id}} = socket) do
    case TableManager.new_hand(tag_id) do
      {:ok, _table} -> {:noreply, socket}
      {:error, reason} -> {:noreply, assign(socket, :error, format_error(reason))}
    end
  end

  def handle_event("reset_table", _params, %{assigns: %{role: :gm, tag_id: tag_id}} = socket) do
    case TableManager.reset_table(tag_id) do
      {:ok, _table} -> {:noreply, socket}
      {:error, reason} -> {:noreply, assign(socket, :error, format_error(reason))}
    end
  end

  # Garde de sécurité — ignore les events GM si pas GM
  def handle_event(event, _params, socket)
      when event in ["start_game", "new_hand", "reset_table"] do
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Privées
  # ---------------------------------------------------------------------------

  defp determine_role(nil, _table), do: :spectator
  defp determine_role(_tag_id, nil), do: :spectator

  defp determine_role(tag_id, %Table{gm_id: gm_id}) when tag_id == gm_id, do: :gm

  defp determine_role(tag_id, %Table{players: players}) do
    if Enum.any?(players, &(&1.id == tag_id)), do: :player, else: :spectator
  end

  defp get_player_from_tag(nil), do: nil

  defp get_player_from_tag(tag_id) do
    case Registry.get_player(tag_id) do
      {:ok, player} -> player
      {:error, _} -> nil
    end
  end

  defp is_my_turn?(%{assigns: %{tag_id: tag_id, table: %Table{hand: hand, players: players}}})
       when not is_nil(hand) do
    current_player = Enum.at(players, hand.current_player_seat)
    current_player && current_player.id == tag_id
  end

  defp is_my_turn?(_socket), do: false

  defp format_error(:not_enough_players), do: "Il faut au moins 2 joueurs."
  defp format_error(:game_already_started), do: "La partie est déjà en cours."
  defp format_error(:not_gm), do: "Action réservée au GM."
  defp format_error(_), do: "Une erreur est survenue."

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :my_turn, is_my_turn?(assigns))

    ~H"""
    <div class="min-h-screen bg-zinc-900 text-white flex flex-col">

      <%!-- Header --%>
      <div class="px-4 py-3 border-b border-zinc-800 flex items-center justify-between">
        <span class="text-zinc-400 text-sm">
          <%= role_label(@role) %>
          <%= if @player, do: "· #{@player.name}" %>
        </span>
        <%= if @table do %>
          <span class="text-zinc-500 text-xs">
            <%= length(@table.players) %> joueur(s) · <%= status_label(@table.status) %>
          </span>
        <% end %>
      </div>

      <%!-- Contenu principal --%>
      <div class="flex-1 flex flex-col items-center justify-center px-4 py-6 space-y-6">

        <%= if is_nil(@table) do %>
          <.no_table role={@role} />
        <% else %>
          <.table_view
            table={@table}
            role={@role}
            my_turn={@my_turn}
            tag_id={@tag_id}
          />
        <% end %>

      </div>

      <%!-- Panel GM (affiché uniquement si GM) --%>
      <%= if @role == :gm do %>
        <.gm_panel table={@table} />
      <% end %>

    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Composants
  # ---------------------------------------------------------------------------

  defp role_label(:gm), do: "GM"
  defp role_label(:player), do: "Joueur"
  defp role_label(:spectator), do: "Spectateur"

  defp status_label(:waiting), do: "En attente"
  defp status_label(:playing), do: "Partie en cours"

  # Pas de table créée
  defp no_table(%{role: :gm} = assigns) do
    ~H"""
    <div class="text-center space-y-2">
      <p class="text-white font-semibold">Aucune table en cours.</p>
      <p class="text-zinc-400 text-sm">Utilisez le panel GM pour créer une partie.</p>
    </div>
    """
  end

  defp no_table(assigns) do
    ~H"""
    <div class="text-center">
      <p class="text-zinc-400">En attente de la table…</p>
    </div>
    """
  end

  # Vue principale de la table
  defp table_view(assigns) do
    ~H"""
    <div class="w-full max-w-sm space-y-6">

      <%!-- Liste des joueurs + stacks --%>
      <div class="space-y-2">
        <%= for player <- @table.players do %>
          <div class={"flex items-center justify-between px-4 py-2 rounded-lg " <>
            if(player.id == @tag_id, do: "bg-zinc-700", else: "bg-zinc-800")}>
            <div class="flex items-center gap-2">
              <%= if player.id == @table.gm_id do %>
                <span class="text-xs text-yellow-400">GM</span>
              <% end %>
              <%= if @table.hand && Enum.at(@table.players, @table.hand.current_player_seat) &&
                     Enum.at(@table.players, @table.hand.current_player_seat).id == player.id do %>
                <span class="w-2 h-2 rounded-full bg-green-400 inline-block"></span>
              <% end %>
              <span class="font-medium"><%= player.name %></span>
              <%= if player.status == :folded do %>
                <span class="text-xs text-zinc-500">couché</span>
              <% end %>
              <%= if player.status == :all_in do %>
                <span class="text-xs text-red-400">all-in</span>
              <% end %>
            </div>
            <span class="text-zinc-300 font-mono"><%= player.stack %></span>
          </div>
        <% end %>
      </div>

      <%!-- Pot (si main en cours) --%>
      <%= if @table.hand do %>
        <div class="text-center">
          <p class="text-zinc-400 text-sm">Pot</p>
          <p class="text-2xl font-bold"><%= @table.hand.pot %></p>
          <p class="text-zinc-500 text-xs mt-1"><%= round_label(@table.hand.current_round) %></p>
        </div>
      <% end %>

      <%!-- Actions joueur (uniquement si c'est son tour) --%>
      <%= if @my_turn do %>
        <.player_actions />
      <% end %>

    </div>
    """
  end

  # Actions disponibles pour le joueur dont c'est le tour
  # (les montants réels seront calculés par TableManager — phase 2)
  defp player_actions(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-center text-green-400 font-semibold">C'est votre tour</p>
      <div class="grid grid-cols-3 gap-2">
        <button
          phx-click="action"
          phx-value-type="check"
          class="bg-zinc-700 hover:bg-zinc-600 py-3 rounded-lg text-sm font-medium transition-colors"
        >
          Check
        </button>
        <button
          phx-click="action"
          phx-value-type="call"
          class="bg-zinc-700 hover:bg-zinc-600 py-3 rounded-lg text-sm font-medium transition-colors"
        >
          Call
        </button>
        <button
          phx-click="action"
          phx-value-type="fold"
          class="bg-red-900 hover:bg-red-800 py-3 rounded-lg text-sm font-medium transition-colors"
        >
          Fold
        </button>
      </div>
      <button
        phx-click="action"
        phx-value-type="raise"
        class="w-full bg-zinc-700 hover:bg-zinc-600 py-3 rounded-lg text-sm font-medium transition-colors"
      >
        Raise
      </button>
    </div>
    """
  end

  # Panel GM — épinglé en bas de page
  defp gm_panel(%{table: nil} = assigns) do
    ~H"""
    <div class="border-t border-zinc-800 px-4 py-4 space-y-2">
      <p class="text-xs text-zinc-500 text-center mb-3">Panel GM</p>
      <p class="text-zinc-400 text-sm text-center">
        Aucune table — démarrez une partie depuis le TableManager.
      </p>
    </div>
    """
  end

  defp gm_panel(%{table: %Table{status: :waiting}} = assigns) do
    ~H"""
    <div class="border-t border-zinc-800 px-4 py-4 space-y-2">
      <p class="text-xs text-zinc-500 text-center mb-3">Panel GM</p>
      <button
        phx-click="start_game"
        class="w-full bg-green-700 hover:bg-green-600 py-3 rounded-lg font-semibold transition-colors"
      >
        Démarrer la partie
      </button>
      <button
        phx-click="reset_table"
        class="w-full bg-zinc-800 hover:bg-zinc-700 py-2 rounded-lg text-sm text-zinc-400 transition-colors"
      >
        Réinitialiser la table
      </button>
    </div>
    """
  end

  defp gm_panel(%{table: %Table{status: :playing}} = assigns) do
    ~H"""
    <div class="border-t border-zinc-800 px-4 py-4 space-y-2">
      <p class="text-xs text-zinc-500 text-center mb-3">Panel GM</p>
      <button
        phx-click="new_hand"
        class="w-full bg-blue-700 hover:bg-blue-600 py-3 rounded-lg font-semibold transition-colors"
      >
        Nouvelle main
      </button>
      <button
        phx-click="reset_table"
        class="w-full bg-zinc-800 hover:bg-zinc-700 py-2 rounded-lg text-sm text-zinc-400 transition-colors"
      >
        Fin de partie
      </button>
    </div>
    """
  end

  defp round_label(:preflop), do: "Préflop"
  defp round_label(:flop), do: "Flop"
  defp round_label(:turn), do: "Turn"
  defp round_label(:river), do: "River"
  defp round_label(:showdown), do: "Abattage"
  defp round_label(_), do: ""
end
