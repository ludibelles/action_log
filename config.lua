Config = {}

-- Discord webhook URL.
-- Keep this server-side only; it is never transmitted to clients.
Config.WebhookURL = ""

-- How long each player's turn lasts, in milliseconds (default: 5 minutes).
Config.TurnDuration = 300000

-- How early to send the "time is running out" warning, in milliseconds
-- before the turn ends (default: 1 minute).
Config.WarningTime = 60000

-- Default dice difficulty when the player omits the argument.
Config.DefaultDifficulty = 6

-- Hard clamps applied to every roll.
Config.MinDifficulty = 2
Config.MaxDifficulty = 10

-- Keybind used to toggle the combat UI panel (registered via RegisterKeyMapping).
Config.UIKeybind = "F6"

-- Tie-break rule.
-- TODO: verify tie-break rule against the book (V20 p.___ / W20 p.___)
-- "players decide" = post the tie to Discord and let anyone call /setorder to resolve it.
Config.TIE_BREAK = "players decide"
