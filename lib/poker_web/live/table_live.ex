defmodule PokerWeb.TableLive do
  use PokerWeb, :live_view

  alias Poker.Players.Registry
  alias Poker.TableManager
  alias Poker.TableManager.Table
  import PokerWeb.TableLiveComponents

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
      |> assign(:error, nil)

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
     |> assign(:role, role)
     |> assign(:error, nil)}
  end

  # ---------------------------------------------------------------------------
  # Events GM
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("start_game", _params, %{assigns: %{role: :gm, tag_id: tag_id}} = socket) do
    case TableManager.start_game(tag_id) do
      {:ok, table} -> {:noreply, assign(socket, :table, table)}
      {:error, reason} -> {:noreply, assign(socket, :error, format_error(reason))}
    end
  end

  @impl true
  def handle_event("create_table", _params, %{assigns: %{role: :gm, tag_id: tag_id}} = socket) do
    case TableManager.create_table(tag_id) do
      {:ok, table} ->
        {:noreply, assign(socket, :table, table)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, format_error(reason))}
    end
  end

  def handle_event("create_table", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("join_table", _params, %{assigns: %{tag_id: tag_id}} = socket) do
    case TableManager.join_table(tag_id) do
      {:ok, table} ->
        {:noreply, assign(socket, :table, table)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, format_error(reason))}
    end
  end

  def handle_event("join_table", _params, socket), do: {:noreply, socket}

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

  def handle_event(
        "declare_winner",
        %{"winner" => winner_id},
        %{assigns: %{role: :gm, tag_id: tag_id}} = socket
      ) do
    case TableManager.declare_winner(tag_id, winner_id) do
      {:ok, _table} -> {:noreply, socket}
      {:error, reason} -> {:noreply, assign(socket, :error, format_error(reason))}
    end
  end

  def handle_event("declare_winner", _params, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Events joueur
  # ---------------------------------------------------------------------------

  def handle_event("action", %{"type" => type}, %{assigns: %{tag_id: tag_id}} = socket)
      when type in ["fold", "check", "call", "all_in"] do
    result =
      case type do
        "fold" -> TableManager.fold(tag_id)
        "check" -> TableManager.check(tag_id)
        "call" -> TableManager.call(tag_id)
        "all_in" -> TableManager.all_in(tag_id)
      end

    case result do
      {:ok, _table} -> {:noreply, socket}
      {:error, reason} -> {:noreply, assign(socket, :error, format_error(reason))}
    end
  end

  def handle_event(
        "action",
        %{"type" => "raise", "amount" => amount_str},
        %{assigns: %{tag_id: tag_id}} = socket
      ) do
    case Integer.parse(amount_str) do
      {amount, ""} when amount > 0 ->
        case TableManager.raise_bet(tag_id, amount) do
          {:ok, _table} -> {:noreply, socket}
          {:error, reason} -> {:noreply, assign(socket, :error, format_error(reason))}
        end

      _ ->
        {:noreply, assign(socket, :error, "Montant invalide.")}
    end
  end

  def handle_event("action", _params, socket), do: {:noreply, socket}

  # Garde de sécurité — ignore les events GM si pas GM
  def handle_event(event, _params, socket)
      when event in ["start_game", "new_hand", "reset_table"] do
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Privées
  # ---------------------------------------------------------------------------

  defp determine_role(nil, _table), do: :spectator

  defp determine_role(tag_id, nil) do
    case Registry.lookup(tag_id) do
      {:ok, %Poker.Players.Player{gm: true}} -> :gm
      _ -> :spectator
    end
  end

  defp determine_role(tag_id, %Table{gm_id: gm_id}) when tag_id == gm_id, do: :gm

  defp determine_role(tag_id, %Table{players: players}) do
    if Enum.any?(players, &(&1.id == tag_id)), do: :player, else: :spectator
  end

  defp get_player_from_tag(nil), do: nil

  defp get_player_from_tag(tag_id) do
    case Registry.lookup(tag_id) do
      {:ok, player} -> player
      {:error, _} -> nil
    end
  end

  defp is_my_turn?(%{tag_id: tag_id, table: %Table{hand: hand, players: players}})
       when not is_nil(hand) do
    current_player = Enum.at(players, hand.current_player_seat)
    current_player && current_player.id == tag_id
  end

  defp is_my_turn?(_assigns), do: false

  defp format_error(:not_enough_players), do: "Il faut au moins 2 joueurs."
  defp format_error(:game_already_started), do: "La partie est déjà en cours."
  defp format_error(:not_gm), do: "Action réservée au GM."
  defp format_error(:not_your_turn), do: "Ce n'est pas votre tour."
  defp format_error(:must_call_or_raise), do: "Vous devez suivre ou relancer."
  defp format_error(:insufficient_funds), do: "Pas assez de jetons."
  defp format_error(:not_showdown), do: "L'abattage n'a pas encore eu lieu."
  defp format_error(:player_not_found), do: "Joueur introuvable."
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
          {role_label(@role)}
          {if @player, do: "· #{@player.name}"}
        </span>
        <%= if @table do %>
          <span class="text-zinc-500 text-xs">
            {length(@table.players)} joueur(s) · {status_label(@table.status)}
          </span>
        <% end %>
      </div>

      <%!-- Contenu principal --%>
      <div class="flex-1 flex flex-col items-center justify-center px-4 py-6 space-y-6">
        <%= if @error do %>
          <div class="w-full max-w-sm bg-red-900/60 border border-red-700 text-red-200 text-sm px-4 py-3 rounded-lg">
            {@error}
          </div>
        <% end %>

        <%= if is_nil(@table) do %>
          <.no_table role={@role} />
        <% else %>
          <.table_view
            table={@table}
            role={@role}
            my_turn={@my_turn}
            tag_id={@tag_id}
            player={@player}
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
  # Vue helpers
  # ---------------------------------------------------------------------------

  defp role_label(:gm), do: "GM"
  defp role_label(:player), do: "Joueur"
  defp role_label(:spectator), do: "Spectateur"

  defp status_label(:waiting), do: "En attente"
  defp status_label(:playing), do: "Partie en cours"
end
