defmodule Poker.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @env Mix.env()

  @impl true
  def start(_type, _args) do
    dns_children = if @env == :prod, do: [Poker.DnsServer], else: []

    children =
      [
        PokerWeb.Telemetry,
        Poker.Repo,
        {DNSCluster, query: Application.get_env(:poker, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Poker.PubSub},
        PokerWeb.Endpoint
      ] ++ dns_children

    opts = [strategy: :one_for_one, name: Poker.Supervisor]
    {:ok, sup} = Supervisor.start_link(children, opts)

    # On Nerves there's no shell to run `mix ecto.migrate`, so we run migrations
    # before starting workers that query the DB (e.g. Players.Registry).
    if @env == :prod do
      {:ok, _, _} = Ecto.Migrator.with_repo(Poker.Repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    for worker <- workers() do
      {:ok, _} = Supervisor.start_child(sup, worker)
    end

    {:ok, sup}
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PokerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp workers do
    if @env == :test do
      []

      # ← en test, on ne démarre pas les GenServers
    else
      [
        Poker.Players.Registry,
        Poker.TableManager
      ]
    end
  end
end
