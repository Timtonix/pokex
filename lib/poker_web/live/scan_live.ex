defmodule PokerWeb.ScanLive do
  use PokerWeb, :live_view

  alias Poker.Players.Registry

  # ---------------------------------------------------------------------------
  # Mount
  # /scan?tag=XXX
  #
  # Cas 1 : pas de tag dans l'URL → message d'erreur
  # Cas 2 : tag inconnu           → formulaire d'enregistrement
  # Cas 3 : tag connu             → redirect /table?tag=XXX
  # ---------------------------------------------------------------------------

  @impl true
  def mount(%{"tag" => tag_id}, _session, socket) do
    case Registry.lookup(tag_id) do
      {:ok, _player} ->
        {:ok, push_navigate(socket, to: ~p"/table?tag=#{tag_id}")}

      {:error, :not_found} ->
        socket =
          socket
          |> assign(:tag_id, tag_id)
          |> assign(:step, :register)
          |> assign(:form, to_form(%{"name" => ""}, as: :registration))
          |> assign(:error, nil)

        {:ok, socket}
    end
  end

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :step, :no_tag)}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("register", %{"registration" => %{"name" => name}}, socket) do
    tag_id = socket.assigns.tag_id
    name = String.trim(name)

    case validate_and_register(tag_id, name) do
      {:ok, _player} ->
        {:noreply, push_navigate(socket, to: ~p"/table?tag=#{tag_id}")}

      {:error, :invalid_name} ->
        {:noreply, assign(socket, :error, "Le pseudo ne peut pas être vide.")}

      {:error, :name_too_long} ->
        {:noreply, assign(socket, :error, "Le pseudo ne peut pas dépasser 20 caractères.")}
    end
  end

  # ---------------------------------------------------------------------------
  # Privées
  # ---------------------------------------------------------------------------

  defp validate_and_register(_tag_id, ""), do: {:error, :invalid_name}

  defp validate_and_register(_tag_id, name) when byte_size(name) > 20,
    do: {:error, :name_too_long}

  defp validate_and_register(tag_id, name) do
    Registry.register(tag_id, name)
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-900 text-white flex items-center justify-center px-4">
      <%= case @step do %>
        <% :no_tag -> %>
          <.no_tag_message />
        <% :register -> %>
          <.register_form tag_id={@tag_id} form={@form} error={@error} />
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Composants
  # ---------------------------------------------------------------------------

  defp no_tag_message(assigns) do
    ~H"""
    <div class="text-center">
      <p class="text-zinc-400 text-lg">Scannez un tag NFC pour continuer.</p>
    </div>
    """
  end

  defp register_form(assigns) do
    ~H"""
    <div class="w-full max-w-sm space-y-6">
      <div class="text-center">
        <h1 class="text-2xl font-bold">Première connexion</h1>
        <p class="text-zinc-400 mt-1">Choisissez votre pseudo pour ce tag.</p>
      </div>

      <%= if @error do %>
        <p class="text-red-400 text-sm text-center">{@error}</p>
      <% end %>

      <.form for={@form} phx-submit="register" class="space-y-4">
        <div>
          <label class="block text-sm text-zinc-400 mb-1">Pseudo</label>
          <.input
            field={@form[:name]}
            type="text"
            placeholder="Ex : Alice"
            autocomplete="off"
            autofocus
          />
        </div>
        <button
          type="submit"
          class="w-full bg-white text-zinc-900 font-semibold py-3 rounded-lg
                 hover:bg-zinc-200 transition-colors"
        >
          Rejoindre
        </button>
      </.form>

      <p class="text-zinc-600 text-xs text-center">Tag : {@tag_id}</p>
    </div>
    """
  end
end
