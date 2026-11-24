-- server.lua
-- Action Log — all dice rolling, turn order, timers, and Discord logging live here.
-- No framework dependency. No admin/ACE checks. The server decides everything.

-- ============================================================
-- Encounter state  (single global encounter; extend if multi-room is ever needed)
-- ============================================================

-- Increment this token to cancel all pending Citizen.SetTimeout callbacks
-- without keeping explicit handles.
local timerVersion = 0

local encounter = {
    active         = false,
    id             = nil,
    round          = 0,
    turnsStarted   = false,
    order          = {},   -- { source, name, initRoll, dex, wits, total, status }
    currentTurnIdx = 0,    -- 1-based index into order; 0 = no active turn
    timerStartUnix = 0,    -- os.time() when the current turn started
    hasRolledInit  = {},   -- [playerSource] = true
}

-- ============================================================
-- Utilities
-- ============================================================

local function getPlayerName(src)
    return GetPlayerName(tostring(src)) or ('Player#' .. tostring(src))
end

local function getCurrentTurnSource()
    local p = encounter.order[encounter.currentTurnIdx]
    return p and p.source or nil
end

-- Build a snapshot for broadcasting to clients.
local function getEncounterState()
    -- Express remaining time as a delta so the client's local countdown
    -- stays accurate even when server and client clocks differ slightly.
    local timerRemainingMs = 0
    if encounter.turnsStarted and encounter.timerStartUnix > 0 then
        local endUnix = encounter.timerStartUnix + (Config.TurnDuration / 1000)
        timerRemainingMs = math.max(0, math.floor((endUnix - os.time()) * 1000))
    end

    local rolledInitList = {}
    for src in pairs(encounter.hasRolledInit) do
        table.insert(rolledInitList, src)
    end

    return {
        active           = encounter.active,
        id               = encounter.id,
        round            = encounter.round,
        turnsStarted     = encounter.turnsStarted,
        currentTurnIdx   = encounter.currentTurnIdx,
        timerRemainingMs = timerRemainingMs,
        turnDurationMs   = Config.TurnDuration,
        order            = encounter.order,
        hasRolledInit    = rolledInitList,
    }
end

local function broadcastState()
    TriggerClientEvent('action_log:syncState', -1, getEncounterState())
end

local function notify(src, msg, notifType)
    TriggerClientEvent('action_log:notify', src, msg, notifType or 'info')
end

-- ============================================================
-- Dice engine
-- ============================================================

local function rollPool(pool, difficulty)
    pool       = math.max(0, pool)
    difficulty = math.max(Config.MinDifficulty, math.min(Config.MaxDifficulty, difficulty))

    local dice         = {}
    local rawSuccesses = 0
    local ones         = 0

    for _ = 1, pool do
        local die = math.random(1, 10)
        table.insert(dice, die)
        if die >= difficulty then rawSuccesses = rawSuccesses + 1 end
        if die == 1          then ones         = ones         + 1 end
    end

    local rawNet     = rawSuccesses - ones
    local botch      = (rawSuccesses == 0 and ones > 0)
    local resultType = botch and 'BOTCH'
                    or (rawNet <= 0 and 'FAILURE')
                    or 'SUCCESS'

    return {
        dice         = dice,
        pool         = pool,
        difficulty   = difficulty,
        rawSuccesses = rawSuccesses,
        ones         = ones,
        net          = math.max(0, rawNet),
        rawNet       = rawNet,
        botch        = botch,
        resultType   = resultType,
    }
end

-- ============================================================
-- Discord webhook  (server-side only; URL never leaves the server)
-- ============================================================

local webhookQueue = {}
local webhookBusy  = false

local function processQueue()
    if webhookBusy or #webhookQueue == 0 or Config.WebhookURL == '' then return end
    webhookBusy = true
    local payload = table.remove(webhookQueue, 1)

    PerformHttpRequest(Config.WebhookURL, function(statusCode)
        webhookBusy = false
        if statusCode == 429 then
            -- Rate-limited: put it back and retry after 5 s
            table.insert(webhookQueue, 1, payload)
            Citizen.SetTimeout(5000, processQueue)
        else
            Citizen.SetTimeout(300, processQueue)
        end
    end, 'POST', payload, { ['Content-Type'] = 'application/json' })
end

local function postEmbed(embed)
    table.insert(webhookQueue, json.encode({ embeds = { embed } }))
    processQueue()
end

-- Shared helpers
local function ts()
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local function encFooter()
    return { text = 'Encounter #' .. (encounter.id or '?') }
end

-- Format dice for Discord embed text.
local function diceStr(result)
    local parts = {}
    for _, d in ipairs(result.dice) do
        if d == 1 then
            table.insert(parts, '**[1]**')
        elseif d >= result.difficulty then
            table.insert(parts, '\u{2713}' .. d)  -- ✓
        else
            table.insert(parts, tostring(d))
        end
    end
    return #parts > 0 and table.concat(parts, '  ') or '*(no dice)*'
end

-- Individual log functions
local function logRoll(playerName, reason, result)
    local color = result.resultType == 'SUCCESS' and 5025616
               or result.resultType == 'BOTCH'   and 16711680
               or 9807270

    postEmbed({
        title       = result.resultType .. ' \u{2014} ' .. playerName,
        description = reason ~= '' and ('**' .. reason .. '**') or nil,
        color       = color,
        fields      = {
            { name = 'Pool',          value = tostring(result.pool),         inline = true },
            { name = 'Difficulty',    value = tostring(result.difficulty),   inline = true },
            { name = 'Round / Turn',  value = encounter.round .. ' / ' .. encounter.currentTurnIdx, inline = true },
            { name = 'Dice',          value = diceStr(result),               inline = false },
            { name = 'Raw Successes', value = tostring(result.rawSuccesses), inline = true },
            { name = '1s Rolled',     value = tostring(result.ones),         inline = true },
            { name = 'Net Successes', value = tostring(math.max(0, result.rawNet)), inline = true },
        },
        footer    = encFooter(),
        timestamp = ts(),
    })
end

local function logInitRoll(playerName, dex, wits, die, total, reason)
    postEmbed({
        title       = '\u{1F3B2} Initiative \u{2014} ' .. playerName,
        description = (reason ~= '' and ('*' .. reason .. '*') or nil),
        color       = 1752220,
        fields      = {
            { name = 'Formula', value = '1d10 (' .. die .. ') + Dex ' .. dex .. ' + Wits ' .. wits, inline = false },
            { name = 'Total',   value = tostring(total), inline = true },
        },
        footer    = encFooter(),
        timestamp = ts(),
    })
end

local function logOrder()
    local lines = {}
    for i, p in ipairs(encounter.order) do
        lines[i] = i .. '. **' .. p.name .. '** \u{2014} ' .. p.total
    end
    postEmbed({
        title       = '\u{1F4CB} Initiative Order \u{2014} Round ' .. encounter.round,
        description = table.concat(lines, '\n'),
        color       = 10181046,
        footer      = encFooter(),
        timestamp   = ts(),
    })
end

local function logRoundStart()
    local lines = {}
    for i, p in ipairs(encounter.order) do
        lines[i] = i .. '. ' .. p.name
    end
    postEmbed({
        title       = '\u{1F504} ROUND ' .. encounter.round .. ' START',
        description = table.concat(lines, '\n'),
        color       = 10181046,
        footer      = encFooter(),
        timestamp   = ts(),
    })
end

local function logTurnStart(player)
    postEmbed({
        title  = '\u{25B6}\u{FE0F} Turn Started \u{2014} ' .. player.name,
        color  = 16776960,
        fields = {
            { name = 'Round',  value = tostring(encounter.round),          inline = true },
            { name = 'Turn #', value = tostring(encounter.currentTurnIdx), inline = true },
        },
        footer    = encFooter(),
        timestamp = ts(),
    })
end

local function logTurnSkipped(playerName, reason)
    postEmbed({
        title       = '\u{23ED}\u{FE0F} TURN SKIPPED: ' .. playerName,
        description = 'Action lost \u{2014} ' .. reason,
        color       = 16744272,
        fields      = { { name = 'Round', value = tostring(encounter.round), inline = true } },
        footer      = encFooter(),
        timestamp   = ts(),
    })
end

local function logEndTurn(playerName)
    postEmbed({
        title  = '\u{23F9}\u{FE0F} Turn Ended Early \u{2014} ' .. playerName,
        color  = 7506394,
        fields = { { name = 'Round', value = tostring(encounter.round), inline = true } },
        footer    = encFooter(),
        timestamp = ts(),
    })
end

local function logEncounterStart(playerName)
    postEmbed({
        title       = '\u{2694}\u{FE0F} Encounter Started',
        description = '**' .. playerName .. '** opened encounter **#' .. (encounter.id or '?') .. '**',
        color       = 3447003,
        timestamp   = ts(),
    })
end

local function logEncounterEnd(playerName, encId)
    postEmbed({
        title       = '\u{1F3C1} Encounter Ended',
        description = '**' .. playerName .. '** ended encounter **#' .. encId .. '**',
        color       = 15158332,
        timestamp   = ts(),
    })
end

local function logTieBreak(a, b)
    postEmbed({
        title       = '\u{2696}\u{FE0F} Initiative Tie: ' .. a.name .. ' and ' .. b.name,
        description = 'Both rolled **' .. a.total .. '**.\n'
                   .. 'Config.TIE_BREAK = **"' .. (Config.TIE_BREAK or 'players decide') .. '"**\n'
                   .. 'Use `/setorder` to resolve.',
        color       = 16776960,
        footer      = encFooter(),
        timestamp   = ts(),
    })
end

local function logOrderChanged(playerName)
    postEmbed({
        title     = '\u{1F500} Order Changed by ' .. playerName,
        color     = 16776960,
        footer    = encFooter(),
        timestamp = ts(),
    })
end

-- ============================================================
-- Turn management
-- ============================================================

local function resetStatuses()
    for _, p in ipairs(encounter.order) do
        p.status = 'waiting'
    end
end

local function allTurnsComplete()
    for _, p in ipairs(encounter.order) do
        if p.status == 'waiting' or p.status == 'active' then return false end
    end
    return true
end

-- Forward declaration so startTurn and advanceTurn can mutually reference each other.
local advanceTurn

local function startTurn(idx)
    if not encounter.active then return end
    if idx < 1 or idx > #encounter.order then return end

    encounter.currentTurnIdx  = idx
    local player              = encounter.order[idx]
    player.status             = 'active'

    timerVersion              = timerVersion + 1
    local myVersion           = timerVersion
    encounter.timerStartUnix  = os.time()

    broadcastState()
    TriggerClientEvent('action_log:yourTurn', player.source)
    logTurnStart(player)

    -- 1-minute warning
    local warnDelay = Config.TurnDuration - Config.WarningTime
    if warnDelay > 0 then
        Citizen.SetTimeout(warnDelay, function()
            if timerVersion == myVersion and encounter.active then
                TriggerClientEvent('action_log:turnWarning', player.source)
            end
        end)
    end

    -- Hard timeout
    Citizen.SetTimeout(Config.TurnDuration, function()
        if timerVersion == myVersion and encounter.active then
            player.status = 'skipped'
            TriggerClientEvent('action_log:skipped', player.source)
            logTurnSkipped(player.name, 'timed out, action lost')
            advanceTurn()
        end
    end)
end

advanceTurn = function()
    if not encounter.active then return end

    if allTurnsComplete() then
        -- Everyone has acted or been skipped — start a new round.
        encounter.round = encounter.round + 1
        resetStatuses()
        logRoundStart()
        broadcastState()
        startTurn(1)
        return
    end

    -- Find the next waiting player after the current position.
    local next = encounter.currentTurnIdx + 1
    while next <= #encounter.order do
        if encounter.order[next].status == 'waiting' then
            startTurn(next)
            return
        end
        next = next + 1
    end

    -- All remaining players in this segment were skipped — force a new round.
    encounter.round = encounter.round + 1
    resetStatuses()
    logRoundStart()
    broadcastState()
    startTurn(1)
end

-- ============================================================
-- Core action functions  (called by both commands and NUI events)
-- ============================================================

local function doCombatStart(src)
    if encounter.active then
        notify(src, 'An encounter is already active. Use /combatend first.', 'error')
        return
    end
    local name = getPlayerName(src)

    encounter.active         = true
    encounter.id             = tostring(math.random(10000, 99999))
    encounter.round          = 0
    encounter.turnsStarted   = false
    encounter.order          = {}
    encounter.currentTurnIdx = 0
    encounter.timerStartUnix = 0
    encounter.hasRolledInit  = {}
    timerVersion             = timerVersion + 1

    broadcastState()
    logEncounterStart(name)
    notify(src, 'Encounter #' .. encounter.id .. ' started!', 'success')
end

local function doCombatEnd(src)
    if not encounter.active then
        notify(src, 'No active encounter.', 'error')
        return
    end
    local name  = getPlayerName(src)
    local encId = encounter.id

    timerVersion             = timerVersion + 1  -- cancel any pending timer callbacks
    encounter.active         = false
    encounter.id             = nil
    encounter.round          = 0
    encounter.turnsStarted   = false
    encounter.order          = {}
    encounter.currentTurnIdx = 0
    encounter.timerStartUnix = 0
    encounter.hasRolledInit  = {}

    broadcastState()
    logEncounterEnd(name, encId)
    TriggerClientEvent('action_log:notify', -1, 'Encounter ended by ' .. name .. '.', 'info')
end

local function doInit(src, dex, wits, reason)
    if not encounter.active then
        notify(src, 'No active encounter. Use /combatstart first.', 'error')
        return
    end
    if encounter.hasRolledInit[src] then
        notify(src, 'You have already rolled initiative this encounter.', 'error')
        return
    end
    if not dex or not wits then
        notify(src, 'Usage: /init [dexterity] [wits] [reason...]', 'error')
        return
    end

    local die   = math.random(1, 10)
    local total = die + dex + wits
    local name  = getPlayerName(src)

    encounter.hasRolledInit[src] = true

    local entry = {
        source   = src,
        name     = name,
        initRoll = die,
        dex      = dex,
        wits     = wits,
        total    = total,
        status   = 'waiting',
    }

    if encounter.turnsStarted then
        -- Mid-encounter join: slot this player at the end of the current round.
        table.insert(encounter.order, entry)
    else
        -- Pre-combat: keep order sorted highest-first.
        local inserted = false
        for i, p in ipairs(encounter.order) do
            if total > p.total then
                table.insert(encounter.order, i, entry)
                inserted = true
                break
            end
        end
        if not inserted then
            table.insert(encounter.order, entry)
        end

        -- Detect ties and post to Discord so players can resolve with /setorder.
        for _, p in ipairs(encounter.order) do
            if p.source ~= src and p.total == total then
                logTieBreak(p, entry)
                break
            end
        end
    end

    logInitRoll(name, dex, wits, die, total, reason or '')
    notify(src, 'Initiative: 1d10(' .. die .. ') + ' .. dex .. ' + ' .. wits .. ' = ' .. total, 'success')

    if not encounter.turnsStarted then
        -- First roll kicks off round 1.
        encounter.turnsStarted   = true
        encounter.round          = 1
        encounter.currentTurnIdx = 0
        logRoundStart()
        logOrder()
        broadcastState()
        startTurn(1)
    else
        broadcastState()
        logOrder()
    end
end

local function doRoll(src, pool, difficulty, reason)
    if not encounter.active then
        notify(src, 'No active encounter.', 'error')
        return
    end
    if encounter.turnsStarted and getCurrentTurnSource() ~= src then
        notify(src, 'It is not your turn.', 'error')
        return
    end
    if not pool then
        notify(src, 'Usage: /roll [pool] [difficulty] [reason...]', 'error')
        return
    end

    difficulty = difficulty or Config.DefaultDifficulty
    reason     = reason or ''

    local name   = getPlayerName(src)
    local result = rollPool(pool, difficulty)
    result.playerName = name
    result.reason     = reason
    result.round      = encounter.round
    result.turnIdx    = encounter.currentTurnIdx

    logRoll(name, reason, result)
    TriggerClientEvent('action_log:rollResult', -1, result)

    if encounter.turnsStarted then
        timerVersion = timerVersion + 1  -- cancel timeout for this turn
        encounter.order[encounter.currentTurnIdx].status = 'acted'
        advanceTurn()
    end
end

local function doEndTurn(src)
    if not encounter.active or not encounter.turnsStarted then
        notify(src, 'No active turn.', 'error')
        return
    end
    if getCurrentTurnSource() ~= src then
        notify(src, 'It is not your turn.', 'error')
        return
    end
    timerVersion = timerVersion + 1
    local player = encounter.order[encounter.currentTurnIdx]
    player.status = 'acted'
    logEndTurn(player.name)
    advanceTurn()
end

local function doSetOrder(src, indices)
    if not encounter.active then
        notify(src, 'No active encounter.', 'error')
        return
    end

    local n        = #encounter.order
    local seen     = {}
    local newOrder = {}

    for _, idx in ipairs(indices) do
        local i = math.floor(idx)
        if i >= 1 and i <= n and not seen[i] then
            seen[i] = true
            table.insert(newOrder, encounter.order[i])
        end
    end

    -- Append any positions not referenced, preserving relative order.
    for i = 1, n do
        if not seen[i] then
            table.insert(newOrder, encounter.order[i])
        end
    end

    -- Keep currentTurnIdx pointing at the same player after reorder.
    local currentSrc = getCurrentTurnSource()
    encounter.order  = newOrder
    if currentSrc then
        for i, p in ipairs(encounter.order) do
            if p.source == currentSrc then
                encounter.currentTurnIdx = i
                break
            end
        end
    end

    local name = getPlayerName(src)
    logOrderChanged(name)
    logOrder()
    broadcastState()
    notify(src, 'Turn order updated.', 'success')
end

local function doShowOrder(src)
    if not encounter.active then
        notify(src, 'No active encounter.', 'error')
        return
    end
    if #encounter.order == 0 then
        notify(src, 'No one has rolled initiative yet.', 'info')
        return
    end
    local lines = {}
    for i, p in ipairs(encounter.order) do
        local marker = (i == encounter.currentTurnIdx) and ' << ACTIVE' or ''
        lines[i] = i .. '. ' .. p.name .. ' (' .. p.total .. ')' .. marker
    end
    notify(src, table.concat(lines, '\n'), 'info')
end

-- ============================================================
-- Commands
-- ============================================================

RegisterCommand('combatstart', function(src) doCombatStart(src) end, false)
RegisterCommand('combatend',   function(src) doCombatEnd(src)   end, false)
RegisterCommand('endturn',     function(src) doEndTurn(src)     end, false)
RegisterCommand('order',       function(src) doShowOrder(src)   end, false)

RegisterCommand('init', function(src, args)
    local dex  = tonumber(args[1])
    local wits = tonumber(args[2])
    local parts = {}
    for i = 3, #args do parts[#parts + 1] = args[i] end
    doInit(src, dex, wits, table.concat(parts, ' '))
end, false)

RegisterCommand('roll', function(src, args)
    local pool       = tonumber(args[1])
    local difficulty = tonumber(args[2])
    local startIdx   = difficulty and 3 or 2
    if not difficulty then difficulty = Config.DefaultDifficulty end
    local parts = {}
    for i = startIdx, #args do parts[#parts + 1] = args[i] end
    doRoll(src, pool, difficulty, table.concat(parts, ' '))
end, false)

RegisterCommand('setorder', function(src, args)
    local indices = {}
    for _, v in ipairs(args) do
        local n = tonumber(v)
        if n then indices[#indices + 1] = n end
    end
    doSetOrder(src, indices)
end, false)

-- ============================================================
-- NUI / Client net events
-- ============================================================

RegisterNetEvent('action_log:requestState')
AddEventHandler('action_log:requestState', function()
    local src = source
    TriggerClientEvent('action_log:syncState', src, getEncounterState())
end)

RegisterNetEvent('action_log:nui_combatstart')
AddEventHandler('action_log:nui_combatstart', function()
    local src = source; doCombatStart(src)
end)

RegisterNetEvent('action_log:nui_combatend')
AddEventHandler('action_log:nui_combatend', function()
    local src = source; doCombatEnd(src)
end)

RegisterNetEvent('action_log:nui_init')
AddEventHandler('action_log:nui_init', function(dex, wits, reason)
    local src = source
    doInit(src, tonumber(dex), tonumber(wits), reason or '')
end)

RegisterNetEvent('action_log:nui_roll')
AddEventHandler('action_log:nui_roll', function(pool, difficulty, reason)
    local src = source
    doRoll(src, tonumber(pool), tonumber(difficulty) or Config.DefaultDifficulty, reason or '')
end)

RegisterNetEvent('action_log:nui_endturn')
AddEventHandler('action_log:nui_endturn', function()
    local src = source; doEndTurn(src)
end)

RegisterNetEvent('action_log:nui_setorder')
AddEventHandler('action_log:nui_setorder', function(ids)
    local src     = source
    local indices = {}
    if type(ids) == 'table' then
        for _, v in ipairs(ids) do
            local n = tonumber(v)
            if n then indices[#indices + 1] = n end
        end
    end
    doSetOrder(src, indices)
end)

-- ============================================================
-- Disconnect handling
-- ============================================================

AddEventHandler('playerDropped', function()
    local src = source
    if not encounter.active then return end

    encounter.hasRolledInit[src] = nil

    for i, p in ipairs(encounter.order) do
        if p.source == src then
            if encounter.turnsStarted and i == encounter.currentTurnIdx then
                -- It was this player's turn; skip and advance.
                timerVersion = timerVersion + 1
                p.status = 'skipped'
                logTurnSkipped(p.name, 'player disconnected')
                advanceTurn()
            elseif p.status == 'waiting' then
                p.status = 'skipped'
                postEmbed({
                    title       = '\u{1F50C} Player Disconnected: ' .. p.name,
                    description = 'Skipped for the rest of this round.',
                    color       = 16744272,
                    footer      = encFooter(),
                    timestamp   = ts(),
                })
                broadcastState()
            end
            break
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    timerVersion = timerVersion + 1  -- invalidate all pending timer callbacks
end)
