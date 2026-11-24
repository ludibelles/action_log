-- client.lua
-- Action Log — NUI relay: key mapping, focus management, event forwarding.
-- Never rolls dice, runs timers, or decides turn order.

local nuiOpen = false
local myId    = GetPlayerServerId(PlayerId())

-- ============================================================
-- Panel toggle
-- ============================================================

local function openPanel()
    nuiOpen = true
    SetNuiFocus(false, true)   -- show cursor so buttons are clickable; keep keyboard for game
    SendNUIMessage({ type = 'setVisible', visible = true })
    TriggerServerEvent('action_log:requestState')
end

local function closePanel()
    nuiOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ type = 'setVisible', visible = false })
end

RegisterCommand('combatui', function()
    if nuiOpen then closePanel() else openPanel() end
end, false)

RegisterKeyMapping('combatui', 'Toggle Combat UI', 'keyboard', Config.UIKeybind)

-- ============================================================
-- NUI callbacks -> server
-- ============================================================

RegisterNUICallback('requestState', function(_, cb)
    TriggerServerEvent('action_log:requestState')
    cb({})
end)

RegisterNUICallback('combatstart', function(_, cb)
    TriggerServerEvent('action_log:nui_combatstart')
    cb({})
end)

RegisterNUICallback('combatend', function(_, cb)
    TriggerServerEvent('action_log:nui_combatend')
    cb({})
end)

RegisterNUICallback('init', function(data, cb)
    TriggerServerEvent('action_log:nui_init', data.dex, data.wits, data.reason or '')
    cb({})
end)

RegisterNUICallback('roll', function(data, cb)
    TriggerServerEvent('action_log:nui_roll', data.pool, data.difficulty, data.reason or '')
    cb({})
end)

RegisterNUICallback('endturn', function(_, cb)
    TriggerServerEvent('action_log:nui_endturn')
    cb({})
end)

RegisterNUICallback('setorder', function(data, cb)
    TriggerServerEvent('action_log:nui_setorder', data.ids or {})
    cb({})
end)

-- Called by NUI when player focuses/blurs a text input.
RegisterNUICallback('setFocus', function(data, cb)
    local focused = data.focused == true
    -- Keep cursor always visible while panel is open;
    -- only toggle keyboard capture so typing doesn't move the character.
    SetNuiFocus(focused, true)
    cb({})
end)

RegisterNUICallback('closePanel', function(_, cb)
    closePanel()
    cb({})
end)

-- ============================================================
-- Server events -> NUI
-- ============================================================

local function sendToNUI(msg)
    if nuiOpen then SendNUIMessage(msg) end
end

RegisterNetEvent('action_log:syncState')
AddEventHandler('action_log:syncState', function(state)
    -- Determine per-client perspective flags before forwarding to the NUI.
    local imt = false   -- isMyTurn
    local ihi = false   -- iHaveInit

    if state.active then
        if state.turnsStarted and state.currentTurnIdx > 0 and state.order then
            local cp = state.order[state.currentTurnIdx]
            if cp and cp.source == myId then imt = true end
        end
        if state.hasRolledInit then
            for _, sid in ipairs(state.hasRolledInit) do
                if sid == myId then ihi = true; break end
            end
        end
    end

    sendToNUI({ type = 'syncState', state = state, isMyTurn = imt, iHaveInit = ihi })
end)

RegisterNetEvent('action_log:rollResult')
AddEventHandler('action_log:rollResult', function(result)
    -- Auto-open the panel so the roll popup is always visible.
    if not nuiOpen then openPanel() end
    SendNUIMessage({ type = 'rollResult', result = result })
end)

RegisterNetEvent('action_log:yourTurn')
AddEventHandler('action_log:yourTurn', function()
    if not nuiOpen then openPanel() end
    SendNUIMessage({ type = 'yourTurn' })
end)

RegisterNetEvent('action_log:skipped')
AddEventHandler('action_log:skipped', function()
    sendToNUI({ type = 'skipped' })
end)

RegisterNetEvent('action_log:turnWarning')
AddEventHandler('action_log:turnWarning', function()
    sendToNUI({ type = 'turnWarning' })
end)

RegisterNetEvent('action_log:notify')
AddEventHandler('action_log:notify', function(msg, notifType)
    sendToNUI({ type = 'notification', message = msg, notifType = notifType or 'info' })
    -- Also mirror to chat so players with the panel closed still see feedback.
    TriggerEvent('chat:addMessage', {
        color     = { 180, 80, 80 },
        multiline = true,
        args      = { '[Action Log]', msg },
    })
end)
