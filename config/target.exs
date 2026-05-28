import Config

config :poker, Poker.Repo, database: "/data/poker_prod.db"

config :poker, PokerWeb.Endpoint,
  url: [host: "192.168.4.1", port: 80],
  http: [ip: {0, 0, 0, 0}, port: 80],
  secret_key_base: "U0YI7m66OwzZhH0tTXkKjx+xfAaARB7fQq/PrXjmcLBy66fpVhzgc/IaA0X7PP/k",
  server: true

config :vintage_net,
  config: [
    {"wlan0",
     %{
       type: VintageNetWiFi,
       vintage_net_wifi: %{
         networks: [
           %{
             mode: :ap,
             ssid: "PokerTable",
             key_mgmt: :none
           }
         ]
       },
       ipv4: %{method: :static, address: "192.168.4.1", prefix_length: 24},
       dhcpd: %{
         start: "192.168.4.2",
         end: "192.168.4.10",
         options: %{
           dns: ["192.168.4.1"],
           subnet: "255.255.255.0",
           router: ["192.168.4.1"]
         }
       }
     }}
  ]

config :nerves_ssh,
  user_passwords: [{"root", "poker"}]

config :logger, backends: [RingLogger]
