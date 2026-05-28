defmodule PokerWeb.TableLiveComponents do
  use PokerWeb, :html

  alias Poker.TableManager.Table

  def table_view(assigns) do
    ~H"""
    <div class="w-full max-w-sm space-y-6">
      <%!-- Liste des joueurs + bankroll --%>
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
              <span class="font-medium">{player.name}</span>
              <%= if player.status == :folded do %>
                <span class="text-xs text-zinc-500">couché</span>
              <% end %>
              <%= if player.status == :all_in do %>
                <span class="text-xs text-red-400">all-in</span>
              <% end %>
            </div>
            <span class="text-zinc-300 font-mono">{player.bankroll}</span>
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

      <%!-- Pot (si main en cours) --%>
      <%= if @table.hand do %>
        <div class="text-center">
          <p class="text-zinc-400 text-sm">Pot</p>
          <p class="text-2xl font-bold">{@table.hand.pot}</p>
          <p class="text-zinc-500 text-xs mt-1">{round_label(@table.hand.current_round)}</p>
        </div>
      <% end %>

      <%!-- Actions joueur (uniquement si c'est son tour) --%>
      <%= if @my_turn do %>
        <.player_actions />
      <% end %>
    </div>
    """
  end

  def player_actions(assigns) do
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
      <form phx-submit="action" class="flex gap-2">
        <input type="hidden" name="type" value="raise" />
        <input
          type="number"
          name="amount"
          min="1"
          placeholder="Montant"
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

  def gm_panel(%{table: %Table{status: :playing}} = assigns) do
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

  defp round_label(:preflop), do: "Préflop"
  defp round_label(:flop), do: "Flop"
  defp round_label(:turn), do: "Turn"
  defp round_label(:river), do: "River"
  defp round_label(:showdown), do: "Abattage"
  defp round_label(_), do: ""
end
