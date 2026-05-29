defmodule PokerWeb.GmLive do
  use PokerWeb, :live_view

  alias Poker.Players.Registry

  @impl true
  def mount(params, _session, socket) do
    tag_id = Map.get(params, "tag")

    case authorize(tag_id) do
      :ok ->
        {:ok, all_players} = Registry.all()
        players = Enum.sort_by(all_players, & &1.name)

        {:ok,
         socket
         |> assign(:tag_id, tag_id)
         |> assign(:players, players)
         |> assign(:error, nil)}

      :unauthorized ->
        {:ok,
         socket
         |> assign(:tag_id, tag_id)
         |> assign(:players, [])
         |> assign(:error, "Accès réservé au GM.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("delete_player", %{"player_id" => player_id}, socket) do
    case Registry.delete(player_id) do
      :ok ->
        {:noreply, reload_players(socket)}

      {:error, _} ->
        {:noreply, assign(socket, :error, "Impossible de supprimer ce joueur.")}
    end
  end

  @impl true
  def handle_event(
        "set_bankroll",
        %{"player_id" => player_id, "amount" => amount_str},
        socket
      ) do
    case Integer.parse(amount_str) do
      {amount, ""} when amount >= 0 ->
        case Registry.set_bankroll(player_id, amount) do
          {:ok, _} -> {:noreply, reload_players(socket)}
          {:error, _} -> {:noreply, assign(socket, :error, "Erreur lors de la modification.")}
        end

      _ ->
        {:noreply, assign(socket, :error, "Montant invalide.")}
    end
  end

  @impl true
  def handle_event("make_gm", %{"player_id" => player_id}, socket) do
    case Registry.make_gm(player_id) do
      {:ok, _} -> {:noreply, reload_players(socket)}
      {:error, _} -> {:noreply, assign(socket, :error, "Erreur lors de la modification.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-900 text-white flex flex-col">
      <div class="px-4 py-4 border-b border-zinc-800 flex items-center gap-3">
        <.link navigate={~p"/table?tag=#{@tag_id}"} class="text-zinc-400 hover:text-white">
          <.icon name="hero-arrow-left" class="w-5 h-5" />
        </.link>
        <h1 class="text-base font-semibold">Gestion des joueurs</h1>
      </div>

      <div class="flex-1 px-4 py-4 max-w-sm mx-auto w-full space-y-4">
        <%= if @error do %>
          <div class="bg-red-900/60 border border-red-700 text-red-200 text-sm px-4 py-3 rounded-lg">
            {@error}
          </div>
        <% end %>

        <p class="text-xs text-zinc-500">{length(@players)} joueur(s) inscrit(s)</p>

        <div class="space-y-2">
          <%= for {player, i} <- Enum.with_index(@players) do %>
            <div class="rounded-xl bg-zinc-800 px-3 py-3 space-y-2">
              <div class="flex items-center justify-between gap-2">
                <div class="flex items-center gap-2 min-w-0">
                  <%= if player.gm do %>
                    <span class="text-xs font-bold text-yellow-400 shrink-0">GM</span>
                  <% end %>
                  <span class="font-medium truncate">{player.name}</span>
                  <span class="text-zinc-400 font-mono text-sm shrink-0">{player.bankroll}</span>
                </div>
                <div class="flex gap-1 shrink-0">
                  <button
                    phx-click={JS.toggle(to: "#bankroll-form-#{i}")}
                    title="Modifier bankroll"
                    class="text-xs px-2 py-1 rounded bg-zinc-700 hover:bg-zinc-600 transition-colors"
                  >
                    ±
                  </button>
                  <%= unless player.gm do %>
                    <button
                      phx-click="make_gm"
                      phx-value-player_id={player.tag_id}
                      title="Nommer GM"
                      class="text-xs px-2 py-1 rounded bg-zinc-700 hover:bg-zinc-600 transition-colors"
                    >
                      GM
                    </button>
                  <% end %>
                  <button
                    phx-click="delete_player"
                    phx-value-player_id={player.tag_id}
                    data-confirm={"Supprimer #{player.name} ?"}
                    title="Supprimer"
                    class="text-xs px-2 py-1 rounded bg-red-900 hover:bg-red-800 transition-colors"
                  >
                    <.icon name="hero-trash" class="w-3.5 h-3.5" />
                  </button>
                </div>
              </div>
              <form
                id={"bankroll-form-#{i}"}
                phx-submit="set_bankroll"
                class="hidden gap-2"
              >
                <input type="hidden" name="player_id" value={player.tag_id} />
                <input
                  type="number"
                  name="amount"
                  value={player.bankroll}
                  min="0"
                  class="flex-1 bg-zinc-900 text-white rounded-lg px-3 py-2 text-sm border border-zinc-700 focus:outline-none focus:border-indigo-500"
                />
                <button
                  type="submit"
                  class="bg-indigo-700 hover:bg-indigo-600 px-4 py-2 rounded-lg text-sm font-medium transition-colors"
                >
                  OK
                </button>
              </form>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Privées
  # ---------------------------------------------------------------------------

  defp authorize(nil), do: :unauthorized

  defp authorize(tag_id) do
    case Registry.lookup(tag_id) do
      {:ok, %Poker.Players.Player{gm: true}} -> :ok
      _ -> :unauthorized
    end
  end

  defp reload_players(socket) do
    {:ok, all_players} = Registry.all()
    players = Enum.sort_by(all_players, & &1.name)
    socket |> assign(:players, players) |> assign(:error, nil)
  end
end
