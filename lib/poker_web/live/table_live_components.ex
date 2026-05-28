defmodule PokerWeb.TableLiveComponents do
  use PokerWeb, :html

  alias Poker.TableManager.Table

  def table_view(assigns) do
    ~H"""
    <div class="w-full max-w-sm space-y-6">
    <!-- Affiche le POT, et le tour actuel -->
      <%= if @table.hand do %>
        <div class="text-center">
          <p class="text-zinc-400 text-sm">Pot</p>
          <p class="text-2xl font-bold">{@table.hand.pot}</p>
          <p class="text-zinc-500 text-xs mt-1">{round_label(@table.hand.current_round)}</p>
        </div>
      <%end %>
      <%!-- Liste des joueurs + bankroll --%>
      <div class="space-y-2">
        <%= for {player, idx} <- Enum.with_index(@table.players) do %>
          <div class={"flex items-center justify-between px-4 py-2 rounded-lg " <>
            if(player.id == @tag_id, do: "bg-zinc-700", else: "bg-zinc-800")}>
            <div class="flex items-center gap-2">
              <%= if player.id == @table.gm_id do %>
                <span class="text-xs text-yellow-400">GM</span>
              <% end %>
              <%= if @table.status == :playing && idx == @table.dealer_seat do %>
                <span class="text-xs bg-white text-black font-bold rounded-full w-4 h-4 flex items-center justify-center leading-none">D</span>
              <% end %>
              <%= if @table.hand && Enum.at(@table.players, @table.hand.current_player_seat) &&
                     Enum.at(@table.players, @table.hand.current_player_seat).id == player.id do %>
                <span class="w-2 h-2 rounded-full bg-green-400 inline-block"></span>
              <% end %>
              <span class="font-medium">{player.name}</span>
              <%= if player.status == :folded do %>
                <span class="text-xs text-zinc-500">couché</span>
              <% end %>
              <%= if player.status == :all_in do %>
                <span class="text-xs text-red-400">all-in</span>
              <% end %>
            </div>
            <div class="flex flex-col items-end">
              <span class="text-zinc-300 font-mono">{player.bankroll}</span>
              <%= if player.id == @tag_id && @table.hand do %>
                <% my_bet = Map.get(@table.hand.total_bets, player.id, 0) %>
                <%= if my_bet > 0 do %>
                  <span class="text-xs text-yellow-400 font-mono">misé: {my_bet}</span>
                <% end %>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <%= if @table.status == :waiting && @role == :spectator do %>
        <%= if @player do %>
          <div class="w-full">
            <button
              phx-click="join_table"
              class="w-full bg-indigo-600 hover:bg-indigo-500 py-3 rounded-lg font-semibold transition-colors"
            >
              Rejoindre la table
            </button>
          </div>
        <% else %>
          <div class="w-full rounded-2xl border border-zinc-800 bg-zinc-950/50 px-4 py-4 text-center space-y-3">
            <p class="text-zinc-300 text-sm">
              Pour rejoindre la partie, scannez votre tag NFC depuis l'écran de scan.
            </p>
            <.link
              navigate={~p"/scan"}
              class="inline-flex items-center justify-center w-full bg-indigo-600 hover:bg-indigo-500 py-3 rounded-lg font-semibold transition-colors"
            >
              Scanner un tag
            </.link>
          </div>
        <% end %>
      <% end %>

      <%!-- Infos sur les mises (si main en cours) --%>
      <%= if @table.hand do %>
        <% max_bet = @table.hand.bets |> Map.values() |> Enum.max(fn -> 0 end) %>
        <% my_bet = Map.get(@table.hand.bets, @tag_id, 0) %>
        <% to_call = max(max_bet - my_bet, 0) %>
        <% min_to_bet = max(@table.big_blind, @table.hand.last_raise || 0) %>

        <div class="flex justify-around text-sm">
          <div class="text-center">
            <p class="text-zinc-500 text-xs">BB</p>
            <p class="font-mono text-zinc-300">{@table.big_blind}</p>
          </div>
          <div class="text-center">
            <p class="text-zinc-500 text-xs">Min</p>
            <p class="font-mono text-zinc-300">{min_to_bet}</p>
          </div>
          <div class="text-center">
            <p class="text-zinc-500 text-xs">Mise max</p>
            <p class="font-mono text-zinc-300">{max_bet}</p>
          </div>
          <div class="text-center">
            <p class="text-zinc-500 text-xs">Pour suivre</p>
            <p class={"font-mono " <> if(to_call > 0, do: "text-yellow-400", else: "text-green-400")}>{to_call}</p>
          </div>
        </div>
      <% end %>

      <%!-- Actions joueur (uniquement si c'est son tour) --%>
      <%= if @my_turn && @table.hand.current_round != :showdown do %>
        <.player_actions table={@table} tag_id={@tag_id}/>
      <% end %>
    </div>
    """
  end

  def player_actions(assigns) do
    ~H"""
    <% max_bet = @table.hand.bets |> Map.values() |> Enum.max(fn -> 0 end) %>
    <% my_bet = Map.get(@table.hand.bets, @tag_id, 0) %>
    <% can_check = max_bet == my_bet %>
    <div class="space-y-3">
      <div class="grid grid-cols-3 gap-2">
        <button
          phx-click="action"
          phx-value-type="check"
          disabled={not can_check}
           class={"py-3 rounded-lg text-sm font-medium transition-colors " <>
            if(can_check, do: "bg-zinc-700 hover:bg-zinc-600", else: "bg-zinc-800 text-zinc-600 cursor-not-allowed")}
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
      <form phx-submit="action" class="flex gap-2">
        <input type="hidden" name="type" value="raise" />
        <input
          type="number"
          name="amount"
          min={"#{@table.big_blind}"}
          placeholder={"Au moins #{@table.big_blind}"}
          class="flex-1 bg-zinc-800 text-white rounded-lg px-3 py-2 text-sm border border-zinc-700 focus:outline-none focus:border-yellow-500"
        />
        <button
          type="submit"
          class="bg-yellow-700 hover:bg-yellow-600 px-4 py-2 rounded-lg text-sm font-medium transition-colors"
        >
          Raise
        </button>
      </form>
      <button
        phx-click="action"
        phx-value-type="all_in"
        class="w-full bg-orange-800 hover:bg-orange-700 py-3 rounded-lg text-sm font-medium transition-colors"
      >
        All-in
      </button>
    </div>
    """
  end

  def gm_panel(%{table: nil} = assigns) do
    ~H"""
    <div class="border-t border-zinc-800 px-4 py-4 space-y-2">
      <p class="text-xs text-zinc-500 text-center mb-3">Panel GM</p>
      <p class="text-zinc-400 text-sm text-center">Aucune table en cours.</p>
      <button
        phx-click="create_table"
        class="w-full bg-green-700 hover:bg-green-600 py-3 rounded-lg font-semibold transition-colors"
      >
        Créer la table
      </button>
    </div>
    """
  end

  def gm_panel(%{table: %Table{status: :waiting}} = assigns) do
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

  def gm_panel(%{table: %Table{status: :playing, hand: %{current_round: :showdown}}} = assigns) do
    eligible = Enum.filter(assigns.table.players, &(&1.status not in [:folded, :out]))

    assigns = assign(assigns, :eligible, eligible)

    ~H"""
    <div class="border-t border-zinc-800 px-4 py-4 space-y-2">
      <p class="text-xs text-zinc-500 text-center mb-3">Panel GM — Abattage</p>
      <%= for player <- @eligible do %>
        <button
          phx-click="declare_winner"
          phx-value-winner={player.id}
          class="w-full bg-yellow-700 hover:bg-yellow-600 py-3 rounded-lg font-semibold transition-colors"
        >
          {player.name} gagne
        </button>
      <% end %>
      <button
        phx-click="reset_table"
        class="w-full bg-zinc-800 hover:bg-zinc-700 py-2 rounded-lg text-sm text-zinc-400 transition-colors"
      >
        Fin de partie
      </button>
    </div>
    """
  end

  def gm_panel(%{table: %Table{status: :playing, hand: nil}} = assigns) do
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

  def gm_panel(%{table: %Table{status: :playing}} = assigns) do
    ~H"""
    <div class="border-t border-zinc-800 px-4 py-4 space-y-2">
      <p class="text-xs text-zinc-500 text-center mb-3">Panel GM</p>
      <p class="text-xs text-zinc-500 text-center mb-3">RAS</p>
    </div>
    """
  end


  def no_table(%{role: :gm} = assigns) do
    ~H"""
    <div class="text-center space-y-2">
      <p class="text-white font-semibold">Aucune table en cours.</p>
      <p class="text-zinc-400 text-sm">Utilisez le panel GM pour créer une partie.</p>
    </div>
    """
  end

  def no_table(assigns) do
    ~H"""
    <div class="text-center">
      <p class="text-zinc-400">En attente de la table…</p>
    </div>
    """
  end

  def hand_rankings_modal(assigns) do
    ~H"""
    <div
      id="hand-rankings-modal"
      class="hidden fixed bottom-0 left-0 right-0 z-50 bg-zinc-900 border-t border-zinc-700 rounded-t-2xl px-5 pt-4 pb-10 max-h-[75vh] overflow-y-auto"
    >
      <div class="flex items-center justify-between mb-4">
        <h2 class="font-bold text-base">Combinaisons poker</h2>
        <button phx-click={JS.hide(to: "#hand-rankings-modal")} class="text-zinc-400 hover:text-white p-1">
          <.icon name="hero-x-mark" class="w-5 h-5" />
        </button>
      </div>
      <ol class="space-y-3 text-sm">
        <li class="flex items-baseline justify-between gap-2">
          <div>
            <span class="text-yellow-300 font-semibold">1. Quinte flush royale</span>
            <p class="text-zinc-500 text-xs">A K Q J 10 de même couleur</p>
          </div>
        </li>
        <li class="flex items-baseline justify-between gap-2">
          <div>
            <span class="font-semibold">2. Quinte flush</span>
            <p class="text-zinc-500 text-xs">5 cartes en suite de même couleur</p>
          </div>
        </li>
        <li class="flex items-baseline justify-between gap-2">
          <div>
            <span class="font-semibold">3. Carré</span>
            <p class="text-zinc-500 text-xs">4 cartes de même valeur</p>
          </div>
        </li>
        <li class="flex items-baseline justify-between gap-2">
          <div>
            <span class="font-semibold">4. Full house</span>
            <p class="text-zinc-500 text-xs">Brelan + paire</p>
          </div>
        </li>
        <li class="flex items-baseline justify-between gap-2">
          <div>
            <span class="font-semibold">5. Couleur</span>
            <p class="text-zinc-500 text-xs">5 cartes de même couleur (non en suite)</p>
          </div>
        </li>
        <li class="flex items-baseline justify-between gap-2">
          <div>
            <span class="font-semibold">6. Suite</span>
            <p class="text-zinc-500 text-xs">5 cartes en suite (couleurs mixtes)</p>
          </div>
        </li>
        <li class="flex items-baseline justify-between gap-2">
          <div>
            <span class="font-semibold">7. Brelan</span>
            <p class="text-zinc-500 text-xs">3 cartes de même valeur</p>
          </div>
        </li>
        <li class="flex items-baseline justify-between gap-2">
          <div>
            <span class="font-semibold">8. Deux paires</span>
            <p class="text-zinc-500 text-xs">2 paires distinctes</p>
          </div>
        </li>
        <li class="flex items-baseline justify-between gap-2">
          <div>
            <span class="font-semibold">9. Paire</span>
            <p class="text-zinc-500 text-xs">2 cartes de même valeur</p>
          </div>
        </li>
        <li class="flex items-baseline justify-between gap-2">
          <div>
            <span class="text-zinc-400 font-semibold">10. Carte haute</span>
            <p class="text-zinc-500 text-xs">Aucune combinaison — la carte la plus haute l'emporte</p>
          </div>
        </li>
      </ol>
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
