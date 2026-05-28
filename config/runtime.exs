import Config

# Only enable the server via PHX_SERVER env var (cloud / CI deployments).
# On Nerves, `server: true` is already set at compile time in target.exs.
if System.get_env("PHX_SERVER") do
  config :poker, PokerWeb.Endpoint, server: true
end

# Only override the port when PORT is explicitly set.
# On Nerves, target.exs already binds to port 80; don't override it here.
if port = System.get_env("PORT") do
  config :poker, PokerWeb.Endpoint, http: [port: String.to_integer(port)]
end

# The block below is for cloud / host deployments only.
# On Nerves the database path and secret_key_base are set at compile time
# in target.exs, so DATABASE_URL will not be present — skip silently.
if config_env() == :prod && System.get_env("DATABASE_URL") do
  database_url = System.get_env("DATABASE_URL")
  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :poker, Poker.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :poker, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :poker, PokerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
