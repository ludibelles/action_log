# action_log

A FiveM resource that logs tabletop-style combat to Discord. The **server** rolls all dice, runs all timers, and decides turn order. The client and NUI only display data and relay button presses.

---

## Install

1. Drop the `action_log` folder into your `resources/` directory.
2. Add `ensure action_log` to your `server.cfg`.
3. Set your Discord webhook URL in `config.lua`:
   ```lua
   Config.WebhookURL = "https://discord.com/api/webhooks/..."
   ```
4. Adjust `Config.TurnDuration`, `Config.WarningTime`, and `Config.UIKeybind` as needed.
5. Restart the server.

---

## Commands

| Command | Arguments | Who | Description |
|---|---|---|---|
| `/combatstart` | — | anyone | Opens a new encounter. Blocked if one is already active. |
| `/combatend` | — | anyone | Ends the encounter and clears all timers. |
| `/init` | `[dex] [wits] [reason...]` | anyone | Rolls 1d10 + Dex + Wits for initiative. One roll per encounter. |
| `/roll` | `[pool] [difficulty] [reason...]` | active player | Rolls `pool` d10s. Difficulty defaults to 6. Ends your turn. |
| `/endturn` | — | active player | Ends your turn without rolling. |
| `/order` | — | anyone | Prints the current initiative order to chat. |
| `/setorder` | `[pos] [pos] ...` | anyone | Reorders by 1-based position numbers from `/order`. Use to resolve ties. |
| `/combatui` | — | anyone | Toggles the NUI panel (also bound to `F6` by default). |

---

## Dice rules

| Rule | Value | Notes |
|---|---|---|
| Die type | d10 | — |
| Default difficulty | 6 | Configurable per roll |
| Difficulty range | 2 – 10 | Clamped server-side |
| Success | die ≥ difficulty | — |
| Cancel | each 1 cancels one success | — |
| Botch | 0 raw successes **and** ≥ 1 ones | — |
| Failure | net ≤ 0, not a botch | — |

All other V20/W20 mechanics (Willpower, specialties, Rage, soak, etc.) are out of scope and not implemented.

---

## Discord logging

Every action is posted to the configured webhook:

- Encounter start / end (and who triggered it)
- Each initiative roll and the final sorted order
- Round start with the full order
- Turn start, turn skipped (timeout or disconnect), early end-turn
- Every roll: pool, difficulty, each die (successes ✓, 1s **[1]**, misses plain), net successes, result
- Tie-break notices with a prompt to use `/setorder`
- Initiative order changes

Webhook requests are queued server-side and auto-retry after 5 s on HTTP 429.

---

## NUI panel

Toggle with `/combatui` or `F6` (configurable).

- **Tracker** – encounter status, round number, initiative list with per-player status badges, countdown timer with colour-coded progress bar.
- **Initiative form** – visible while the encounter is active and you haven't rolled yet.
- **Roll form** – visible only on your turn.
- **Roll result popup** – shown to everyone for 8 seconds with per-die colour tiles (green = success, red = 1, grey = miss) and a SUCCESS / FAILURE / BOTCH banner.
- **YOUR TURN** banner appears when it's your turn; **SKIPPED** when you time out.

The panel never locks game controls. The cursor is shown while the panel is open; keyboard is only captured while typing in a text field.

---

## Tie-breaking

`Config.TIE_BREAK = "players decide"` (default). When two players roll the same initiative total, the server posts a tie notice to Discord and both players agree out of band, then anyone calls `/setorder` to fix the positions.

> **TODO**: verify tie-break rule against the book (V20 p.___ / W20 p.___) and update `Config.TIE_BREAK` accordingly.

---

## Configuration reference (`config.lua`)

```lua
Config.WebhookURL       -- Discord webhook URL (server-side only)
Config.TurnDuration     -- ms per turn, default 300000 (5 min)
Config.WarningTime      -- ms before turn end to warn, default 60000 (1 min)
Config.DefaultDifficulty -- default roll difficulty, default 6
Config.MinDifficulty    -- lowest allowed difficulty, default 2
Config.MaxDifficulty    -- highest allowed difficulty, default 10
Config.UIKeybind        -- toggle key, default "F6"
Config.TIE_BREAK        -- tie-break rule label posted to Discord
```
