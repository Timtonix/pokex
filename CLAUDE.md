# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
mix setup                          # Install deps, create/migrate DB, build assets
mix phx.server                     # Start dev server (localhost:4000)
iex -S mix phx.server              # Start with interactive shell
mix test                           # Run all tests (auto-creates/migrates test DB)
mix test test/poker/table_manager_test.exs  # Run a single test file
mix test --failed                  # Rerun only previously failed tests
mix precommit                      # compile --warnings-as-errors + format + test (run before committing)
mix ecto.reset                     # Drop and recreate the database
```

## Architecture

This is a **Phoenix LiveView** app for managing a physical poker evening, designed to eventually run on a Raspberry Pi Zero via [Nerves](https://nerves-project.org/). Players join using NFC tags scanned from an iPhone.

### Data flow

```
iPhone scans NFC tag
  → GET /nfc/:tag_id (NfcController)
  → redirect /scan?tag=XXX
  → ScanLive: known player → /table?tag=XXX | unknown → registration form
  → TableLive: subscribes to PubSub "table" topic, role determined (gm/player/spectator)
```

All connected clients receive `{:table_updated, %Table{}}` via `Phoenix.PubSub` whenever game state changes.

### Core processes

**`Poker.Players.Registry`** (`lib/poker/players/registry.ex`) — GenServer  
In-memory `%{tag_id => %Player{}}` map. Loaded from SQLite at startup, all writes go through both memory and SQLite. The NFC tag string is the player's primary key everywhere.

**`Poker.TableManager`** (`lib/poker/table_manager.ex`) — GenServer  
Holds the entire game state in memory as `%Table{}` (starts as `nil`). No persistence — the table is ephemeral (one evening). All game actions are synchronous `GenServer.call/2`.

**`Poker.Repo`** — Ecto + SQLite3  
Only the `players` table persists between sessions: `tag_id`, `name`, `bankroll`, `gm` (boolean), `status`.

### Key structs (all nested in `Poker.TableManager`)

- **`Table`** — top-level state: `table_id`, `gm_id`, `players` (list of `%Player{}`), `status` (`:waiting` | `:playing`), `hand` (`%Hand{}` | nil), `dealer_seat`
- **`Player`** — player at the table: `id` (NFC tag string), `name`, `bankroll`, `seat` (0-based index), `status` (`:active` | `:folded` | `:all_in` | `:out`)
- **`Hand`** — one poker hand: `pot`, `side_pots`, `current_round` (`:preflop`→`:flop`→`:turn`→`:river`→`:showdown`), `current_player_seat`, `last_raise`, `bets` (current round), `total_bets` (full hand), `community_cards_count`

### LiveViews

- **`ScanLive`** (`/scan?tag=XXX`) — first-contact page: registers new players or redirects known ones to `/table`
- **`TableLive`** (`/table?tag=XXX`) — main game view; role-based UI (gm/player/spectator); imports `TableLiveComponents` for all rendering
- **`TableLiveComponents`** (`lib/poker_web/live/table_live_components.ex`) — function components: `table_view`, `player_actions`, `gm_panel`, `no_table`

### Authorization model

The GM is identified by their NFC tag (`table.gm_id`). Actions like `start_game`, `new_hand`, `reset_table`, and `declare_winner` verify the caller's tag matches `gm_id`. Players can only act on their own turn (`current_player_seat`).

### Bankroll invariant

`Player.bankroll` in the GenServer is the source of truth during a hand. SQLite is updated at each bankroll change via `Poker.Repo`. The sum of all player bankrolls plus the current pot must remain constant throughout a hand.

## Testing

In tests, `Poker.Players.Registry` and `Poker.TableManager` are **not** started by the application supervisor — they must be started manually with `start_supervised!`. The test setup grants sandbox access to both GenServers via `Ecto.Adapters.SQL.Sandbox.allow/3`.

Use `:sys.replace_state/2` to inject specific player states (e.g., low bankroll, `:out` status) without going through the public API.

## Important rules (from AGENTS.md)

- Run `mix precommit` when done with all changes and fix any issues before committing
- LiveView templates must begin with `<Layouts.app flash={@flash} ...>` (Phoenix v1.8)
- Use `<.icon name="hero-...">` for icons, never `Heroicons` modules
- Use `<.input>` component from `core_components.ex` for form inputs
- Never nest multiple modules in the same file
- Never use `String.to_atom/1` on user input
- Predicate functions should end in `?`, not start with `is_`
- Elixir lists don't support index access syntax — use `Enum.at/2`
- Always bind the result of `if`/`case`/`cond` blocks to a variable (immutability)
- Tailwind CSS v4: no `tailwind.config.js`, uses `@import "tailwindcss"` syntax in `app.css`
- Never use `@apply` in CSS; never write inline `<script>` tags in templates
- Colocated JS hook names must start with `.` (e.g., `.MyHook`)
- Use `start_supervised!/1` in tests, never `Process.sleep/1`
