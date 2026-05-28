# Poker — Deployment & Architecture Guide

Agent-facing document. Everything needed to understand, build, and deploy this app.

---

## What this is

A **Phoenix LiveView** web app for managing a physical poker evening. It runs on a **Raspberry Pi Zero W** via [Nerves](https://nerves-project.org/). Players join by scanning NFC tags from an iPhone. The Pi hosts a WiFi hotspot; phones connect to it and open the app in a browser.

No internet connection required. No cloud. Everything is local.

---

## Hardware setup

| Component | Detail |
|---|---|
| Board | Raspberry Pi Zero W (rpi0) |
| Storage | MicroSD card |
| Network | Pi acts as WiFi AP (`PokerTable`, no password) |
| Pi IP | `192.168.4.1` |
| App URL | `http://192.168.4.1` (port 80) |
| NFC | iPhone scans tags → redirected to the app via Safari |

---

## Build & deploy (Nerves firmware)

### Prerequisites

```bash
mix archive.install hex nerves_bootstrap
```

Elixir, Erlang, and `fwup` must be installed. On Ubuntu:

```bash
sudo apt install fwup
```

### First-time setup (host dev)

```bash
mix setup        # deps + DB + assets
mix phx.server   # dev server at localhost:4000
```

### Build firmware for the Pi

```bash
MIX_TARGET=rpi0 MIX_ENV=prod mix deps.get
MIX_TARGET=rpi0 MIX_ENV=prod mix firmware
```

Output: `_build/rpi0_prod/nerves/images/poker.fw`

### Burn to SD card

```bash
# Unmount if already mounted
sudo umount /dev/sdb*

MIX_TARGET=rpi0 MIX_ENV=prod mix burn
# Confirm with Y when prompted
```

### OTA update (Pi already running)

```bash
MIX_TARGET=rpi0 MIX_ENV=prod mix upload
```

### After flashing

1. Insert SD card into Pi Zero W
2. Power on the Pi
3. Wait ~30s for boot
4. Connect phone to WiFi `PokerTable` (no password)
5. Open `http://192.168.4.1` in the browser

---

## Key config files

| File | Purpose |
|---|---|
| `config/config.exs` | Base config for all envs. Starts `nerves_bootstrap`. Imports `target.exs` when `MIX_TARGET != :host`. |
| `config/target.exs` | Nerves-only config: SQLite path, endpoint (port 80, `server: true`), VintageNet WiFi AP + DHCP. |
| `config/prod.exs` | Prod-only config: static manifest cache, no SSL on Nerves. |
| `config/runtime.exs` | Runtime config: only active for cloud deploys (`PHX_SERVER`, `DATABASE_URL`). Ignored on Nerves. |
| `rel/vm.args.eex` | Erlang VM flags template, required by Nerves. |
| `rootfs_overlay/` | Files overlaid onto the Nerves root filesystem at build time. Currently empty. |

### WiFi AP config (`config/target.exs`)

```elixir
config :vintage_net,
  config: [
    {"wlan0", %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [%{mode: :ap, ssid: "PokerTable", key_mgmt: :none}]
      },
      ipv4: %{method: :static, address: "192.168.4.1", prefix_length: 24},
      dhcpd: %{
        start: "192.168.4.2",
        end: "192.168.4.10",
        options: %{dns: ["192.168.4.1"], subnet: "255.255.255.0", router: ["192.168.4.1"]}
      }
    }}
  ]
```

The `dhcpd` block is mandatory — without it phones connect to the AP but never get an IP.

---

## Architecture

### Data flow

```
iPhone scans NFC tag
  → GET /nfc/:tag_id            (NfcController)
  → redirect /scan?tag=TAG_ID
  → ScanLive: known player?
      yes → redirect /table?tag=TAG_ID
      no  → registration form
  → TableLive: subscribes to PubSub "table" topic
      role = :gm | :player | :spectator
```

All connected clients receive `{:table_updated, %Table{}}` via `Phoenix.PubSub` on every state change.

### Supervision tree

```
Poker.Supervisor (one_for_one)
├── PokerWeb.Telemetry
├── Poker.Repo               (Ecto + SQLite3)
├── DNSCluster
├── Phoenix.PubSub
├── PokerWeb.Endpoint
├── Poker.Players.Registry   (GenServer — NOT started in :test)
└── Poker.TableManager       (GenServer — NOT started in :test)
```

On Nerves boot, `Ecto.Migrator` runs all migrations automatically (no shell available).

### Core processes

#### `Poker.Players.Registry` (`lib/poker/players/registry.ex`)

GenServer holding `%{tag_id => %Player{}}` in memory. Loaded from SQLite at startup. All writes go through both memory and SQLite atomically.

Public API:
- `lookup(tag_id)` → `{:ok, player} | {:error, :not_found}`
- `register(tag_id, name, bankroll \\ 10000)` → `{:ok, player} | {:error, :already_registered}`
- `update_bankroll(tag_id, amount)` — amount can be negative
- `set_status(tag_id, status)` — `:active | :away | :out`
- `all()` → list of all players

#### `Poker.TableManager` (`lib/poker/table_manager.ex`)

GenServer holding the entire game state as `%Table{}` (starts as `nil`). No persistence — the table is ephemeral (one evening session).

Public API:
- `create_table(gm_tag)` — creates a new table; GM must have `gm: true` in Registry
- `join_table(tag_id)` — adds a player; table must be `:waiting`
- `start_game(caller_tag)` — GM only; requires ≥ 2 players
- `reset_table(caller_tag)` — GM only; clears hand and players, re-adds GM at seat 0
- `get_state()` → current `%Table{}`

---

## Key structs

### `Table`

```elixir
%Table{
  table_id: "uuid",
  gm_id: "NFC-TAG-STRING",       # tag of the GM player
  players: [%Player{}],          # ordered list, index = seat
  status: :waiting | :playing,
  hand: %Hand{} | nil,
  dealer_seat: 0                 # 0-based index into players
}
```

Max 6 players (`Table.max_players/0`).

### `Player` (at table)

```elixir
%Player{
  id: "NFC-TAG-STRING",          # primary key, same as SQLite tag_id
  name: "Alice",
  bankroll: 10000,               # source of truth during hand; synced to SQLite
  seat: 0,                       # 0-based, assigned at join time
  status: :active | :folded | :all_in | :out
}
```

### `Hand`

```elixir
%Hand{
  pot: 0,
  side_pots: [],                 # [{amount, [eligible_ids]}]
  current_round: :preflop,       # → :flop → :turn → :river → :showdown
  current_player_seat: 1,
  last_raise: nil,
  bets: %{},                     # current round bets, reset each round
  total_bets: %{},               # cumulative for side-pot calculation
  community_cards_count: 0       # 0|3|4|5
}
```

### `Poker.Players.Player` (SQLite schema)

```elixir
%Poker.Players.Player{
  tag_id: "NFC-TAG-STRING",      # primary key
  name: "Alice",
  bankroll: 10000,
  gm: false,                     # true = this player can create tables
  status: "active"
}
```

---

## LiveViews

| Module | Route | Purpose |
|---|---|---|
| `ScanLive` | `/scan?tag=TAG` | First-contact: register new player or redirect to table |
| `TableLive` | `/table?tag=TAG` | Main game view, role-based UI |
| `TableLiveComponents` | (imported) | All rendering: `table_view`, `player_actions`, `gm_panel`, `no_table` |

### Role determination in `TableLive`

- `:gm` — `tag_id == table.gm_id`
- `:player` — tag is in `table.players`
- `:spectator` — no tag, or unknown tag

GM sees: create table, start game, new hand, reset table, declare winner buttons.
Players see: their own action buttons (fold, call, raise, all-in) only on their turn.
Spectators see read-only view.

---

## Authorization rules

- `create_table`, `start_game`, `reset_table`, `new_hand`, `declare_winner` — GM only (verified by `tag == table.gm_id` and `gm: true` in Registry)
- Player actions (fold, call, raise) — only when `current_player_seat == player.seat`
- `join_table` — any registered player, table must be `:waiting`, not full

---

## Database

SQLite via `ecto_sqlite3`. Only `players` persists between sessions.

```sql
CREATE TABLE players (
  tag_id   TEXT PRIMARY KEY,
  name     TEXT NOT NULL,
  bankroll INTEGER NOT NULL DEFAULT 10000,
  gm       BOOLEAN NOT NULL DEFAULT false,
  status   TEXT NOT NULL DEFAULT 'active'
);
```

On Nerves: DB lives at `/data/poker_prod.db` (persists across reboots).
On host dev: `poker_dev.db` at project root.

Migrations run automatically at boot on Nerves (`Ecto.Migrator` in `Application.start/2`).

---

## Bankroll invariant

`Player.bankroll` in the GenServer is the source of truth during a hand. SQLite is updated at every bankroll change via `Poker.Repo`. The sum of all player bankrolls plus the current pot must remain constant throughout a hand.

---

## Testing

```bash
mix test                                              # all tests
mix test test/poker/table_manager_test.exs            # single file
mix test --failed                                     # rerun failures
```

`Poker.Players.Registry` and `Poker.TableManager` are **not** started by the supervisor in `:test` env — start them manually:

```elixir
start_supervised!(Poker.Players.Registry)
start_supervised!(Poker.TableManager)
Ecto.Adapters.SQL.Sandbox.allow(Poker.Repo, self(), GenServer.whereis(Poker.TableManager))
```

Use `:sys.replace_state/2` to inject specific player states without going through the public API.

---

## Known issues / TODO

- `TableManager.new_hand/1` is not yet implemented (called in `TableLive` but undefined — causes a compile warning).
- `PokerWeb.GmLive` is referenced in the router but the module does not exist yet.
- `NfcController` redirects to `/players/new` which has no route.
- GM does not automatically re-join the player list after `reset_table` (it does after `create_table`).
- `TableManager.start_game/1` does not broadcast `{:table_updated, table}` via PubSub — other clients won't update unless they trigger a `get_state` themselves.

---

## Useful commands

```bash
mix precommit                              # compile + format + test (run before committing)
mix ecto.reset                             # drop and recreate dev DB
iex -S mix phx.server                     # dev server with interactive shell
MIX_TARGET=rpi0 MIX_ENV=prod mix firmware # build firmware
MIX_TARGET=rpi0 MIX_ENV=prod mix burn     # write to SD card
MIX_TARGET=rpi0 MIX_ENV=prod mix upload   # OTA update to running Pi
```
