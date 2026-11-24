// script.js — Action Log NUI
// Receives state from the client script via window.addEventListener('message', ...)
// and sends player actions back via fetch (NUI callbacks).
// No game logic lives here; the server decides everything.

'use strict';

// ============================================================
// Local state
// ============================================================

let state = {
    active: false, id: null, round: 0,
    turnsStarted: false, currentTurnIdx: 0,
    timerRemainingMs: 0, turnDurationMs: 300000,
    order: [], hasRolledInit: []
};
let isMyTurn  = false;
let iHaveInit = false;

// Local end-time for the countdown (Date.now() + remaining when state arrived).
let timerEndLocal    = 0;
let timerIntervalId  = null;

// Roll popup timers
let popupHideTimer  = null;
let popupFadeTimer  = null;

// ============================================================
// NUI ↔ client bridge
// ============================================================

function nuiPost(endpoint, data) {
    return fetch(`https://action_log/${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data || {})
    }).catch(() => {});
}

// ============================================================
// Message handler (server → client → NUI)
// ============================================================

window.addEventListener('message', function (e) {
    const msg = e.data;
    if (!msg || !msg.type) return;

    switch (msg.type) {
        case 'setVisible':   handleSetVisible(msg.visible);                break;
        case 'syncState':    handleSyncState(msg);                         break;
        case 'rollResult':   showRollResult(msg.result);                   break;
        case 'yourTurn':     showBanner('your-turn-banner', 4000);         break;
        case 'skipped':      showBanner('skipped-banner', 4000);           break;
        case 'turnWarning':  handleTurnWarning();                          break;
        case 'notification': showNotification(msg.message, msg.notifType); break;
    }
});

// ============================================================
// Visibility
// ============================================================

function handleSetVisible(visible) {
    const app = document.getElementById('app');
    if (visible) {
        app.classList.remove('hidden');
        nuiPost('requestState');
    } else {
        app.classList.add('hidden');
    }
}

// ============================================================
// State sync
// ============================================================

function handleSyncState(msg) {
    state     = msg.state;
    isMyTurn  = !!msg.isMyTurn;
    iHaveInit = !!msg.iHaveInit;

    // Anchor the local countdown using the server-reported remaining time.
    // This resyncs on every state broadcast, compensating for clock drift.
    if (state.turnsStarted && state.timerRemainingMs > 0) {
        timerEndLocal = Date.now() + state.timerRemainingMs;
    } else {
        timerEndLocal = 0;
    }

    updateAll();
    ensureTimerRunning();
}

function updateAll() {
    updateHeader();
    updateInitiativeList();
    updateTimer();
    updateActionPanel();
}

// ============================================================
// Header
// ============================================================

function updateHeader() {
    const badge = document.getElementById('encounter-badge');
    const lbl   = document.getElementById('round-label');

    if (state.active) {
        badge.textContent = 'ACTIVE';
        badge.className   = 'badge active';
        lbl.textContent   = state.round > 0 ? 'Round ' + state.round : '';
    } else {
        badge.textContent = 'INACTIVE';
        badge.className   = 'badge inactive';
        lbl.textContent   = '';
    }
}

// ============================================================
// Initiative list
// ============================================================

function updateInitiativeList() {
    const list  = document.getElementById('initiative-list');
    const empty = document.getElementById('initiative-empty');

    // Clear existing player rows (but keep #initiative-empty in place).
    list.querySelectorAll('.player-row').forEach(r => r.remove());

    if (!state.order || state.order.length === 0) {
        empty.classList.remove('hidden');
        return;
    }
    empty.classList.add('hidden');

    state.order.forEach((player, i) => {
        const idx = i + 1; // 1-based

        const row = document.createElement('div');
        row.className = 'player-row';
        if (idx === state.currentTurnIdx) row.classList.add('active-turn');

        const pos = el('div', 'player-position', String(idx) + '.');
        const nm  = el('div', 'player-name', player.name);
        const iv  = el('div', 'player-init', String(player.total));
        const sb  = el('div', 'status-badge ' + (player.status || 'waiting'),
                        (player.status || 'waiting').toUpperCase());

        row.append(pos, nm, iv, sb);
        list.insertBefore(row, empty);
    });
}

// ============================================================
// Timer
// ============================================================

function ensureTimerRunning() {
    if (!timerIntervalId) {
        timerIntervalId = setInterval(updateTimer, 100);
    }
}

function updateTimer() {
    const section = document.getElementById('timer-section');
    const display = document.getElementById('timer-display');
    const fill    = document.getElementById('timer-fill');

    if (!state.turnsStarted || timerEndLocal === 0) {
        section.classList.add('hidden');
        return;
    }
    section.classList.remove('hidden');

    const remaining = Math.max(0, timerEndLocal - Date.now());
    const fraction  = remaining / (state.turnDurationMs || 300000);

    const mins = Math.floor(remaining / 60000);
    const secs = Math.floor((remaining % 60000) / 1000);
    display.textContent = pad2(mins) + ':' + pad2(secs);
    fill.style.width    = (fraction * 100).toFixed(2) + '%';

    const urgency = remaining < 30000 ? 'critical'
                  : remaining < 60000 ? 'warning'
                  : 'normal';
    display.dataset.urgency = urgency;
    fill.dataset.urgency    = urgency;
}

// ============================================================
// Action panel
// ============================================================

function updateActionPanel() {
    const startBtn = document.getElementById('btn-start-encounter');
    const endBtn   = document.getElementById('btn-end-encounter');
    const initForm = document.getElementById('init-form');
    const rollForm = document.getElementById('roll-form');

    if (state.active) {
        startBtn.classList.add('hidden');
        endBtn.classList.remove('hidden');
        // Show initiative form while player hasn't rolled yet.
        setVisible(initForm, !iHaveInit);
        // Show roll form only on this player's active turn.
        setVisible(rollForm, isMyTurn && state.turnsStarted);
    } else {
        startBtn.classList.remove('hidden');
        endBtn.classList.add('hidden');
        initForm.classList.add('hidden');
        rollForm.classList.add('hidden');
    }
}

// ============================================================
// Roll result popup
// ============================================================

function showRollResult(result) {
    const popup = document.getElementById('roll-popup');

    // Player + reason
    document.getElementById('popup-player-name').textContent = result.playerName || '';
    document.getElementById('popup-reason').textContent      = result.reason || '';

    // Dice tiles
    const diceRow = document.getElementById('popup-dice-row');
    diceRow.innerHTML = '';
    (result.dice || []).forEach(die => {
        const type = die === 1 ? 'one' : die >= result.difficulty ? 'success' : 'miss';
        const tile = el('div', 'die-tile', String(die));
        tile.dataset.type = type;
        diceRow.appendChild(tile);
    });

    // Stats row
    const stats = document.getElementById('popup-stats');
    stats.innerHTML = '';
    [
        ['Pool',       result.pool],
        ['Difficulty', result.difficulty],
        ['Successes',  result.rawSuccesses],
        ['1s',         result.ones],
        ['Net',        Math.max(0, result.rawNet || 0)],
    ].forEach(([label, val]) => {
        const item = el('div', 'stat-item');
        item.append(el('span', 'stat-label', label), el('span', 'stat-value', String(val)));
        stats.appendChild(item);
    });

    // Result banner
    const banner = document.getElementById('popup-result-banner');
    banner.textContent    = result.resultType || '';
    banner.dataset.result = (result.resultType || '').toLowerCase();

    document.getElementById('popup-subtext').textContent =
        'Round ' + (result.round || '?') + '  \u2022  Turn ' + (result.turnIdx || '?');

    // Reset and show
    clearTimeout(popupHideTimer);
    clearTimeout(popupFadeTimer);
    popup.classList.remove('hidden', 'fade-out', 'visible');
    void popup.offsetWidth; // force reflow so animation restarts
    popup.classList.add('visible');

    popupHideTimer = setTimeout(() => {
        popup.classList.add('fade-out');
        popupFadeTimer = setTimeout(() => {
            popup.classList.remove('visible', 'fade-out');
            popup.classList.add('hidden');
        }, 460);
    }, 8000);
}

// ============================================================
// Banners (YOUR TURN / SKIPPED)
// ============================================================

function showBanner(id, duration) {
    const el = document.getElementById(id);
    el.classList.remove('hidden', 'fade-out', 'visible');
    void el.offsetWidth;
    el.classList.add('visible');

    setTimeout(() => {
        el.classList.add('fade-out');
        setTimeout(() => {
            el.classList.remove('visible', 'fade-out');
            el.classList.add('hidden');
        }, 460);
    }, duration);
}

// ============================================================
// Turn warning
// ============================================================

function handleTurnWarning() {
    const section = document.getElementById('timer-section');
    section.classList.remove('warning-pulse');
    void section.offsetWidth;
    section.classList.add('warning-pulse');
    section.addEventListener('animationend', () =>
        section.classList.remove('warning-pulse'), { once: true });
    showNotification('\u26A0\uFE0F 1 minute remaining on your turn!', 'warning');
}

// ============================================================
// Notifications (toast)
// ============================================================

function showNotification(message, type) {
    const container = document.getElementById('notifications');
    const note      = el('div', 'notification ' + (type || 'info'), message);
    container.appendChild(note);

    // Two rAF ticks to ensure the browser paints before the transition starts.
    requestAnimationFrame(() => requestAnimationFrame(() => note.classList.add('visible')));

    setTimeout(() => {
        note.classList.remove('visible');
        setTimeout(() => note.remove(), 280);
    }, 4000);
}

// ============================================================
// Button event listeners
// ============================================================

document.getElementById('btn-start-encounter').addEventListener('click', () =>
    nuiPost('combatstart'));

document.getElementById('btn-end-encounter').addEventListener('click', () =>
    document.getElementById('confirm-overlay').classList.remove('hidden'));

document.getElementById('confirm-yes').addEventListener('click', () => {
    document.getElementById('confirm-overlay').classList.add('hidden');
    nuiPost('combatend');
});

document.getElementById('confirm-no').addEventListener('click', () =>
    document.getElementById('confirm-overlay').classList.add('hidden'));

document.getElementById('btn-roll-init').addEventListener('click', () => {
    const dex    = parseInt(document.getElementById('init-dex').value,  10);
    const wits   = parseInt(document.getElementById('init-wits').value, 10);
    const reason = document.getElementById('init-reason').value.trim();

    if (!Number.isFinite(dex)  || dex  < 1 || dex  > 10)
        return showNotification('Enter a valid Dexterity (1\u201310).', 'error');
    if (!Number.isFinite(wits) || wits < 1 || wits > 10)
        return showNotification('Enter a valid Wits (1\u201310).', 'error');

    nuiPost('init', { dex, wits, reason });
    document.getElementById('init-dex').value    = '';
    document.getElementById('init-wits').value   = '';
    document.getElementById('init-reason').value = '';
});

document.getElementById('btn-roll').addEventListener('click', () => {
    const pool   = parseInt(document.getElementById('roll-pool').value,   10);
    const diff   = parseInt(document.getElementById('roll-diff').value,   10) || 6;
    const reason = document.getElementById('roll-reason').value.trim();

    if (!Number.isFinite(pool) || pool < 1)
        return showNotification('Enter a valid dice pool (at least 1).', 'error');

    nuiPost('roll', { pool, difficulty: diff, reason });
    document.getElementById('roll-pool').value   = '';
    document.getElementById('roll-reason').value = '';
});

document.getElementById('btn-end-turn').addEventListener('click', () =>
    nuiPost('endturn'));

document.getElementById('btn-close').addEventListener('click', () =>
    nuiPost('closePanel'));

// ============================================================
// Focus management
// ============================================================

// Capture keyboard for NUI while typing; release to game when done.
document.querySelectorAll('input').forEach(input => {
    input.addEventListener('focus', () => nuiPost('setFocus', { focused: true }));
    input.addEventListener('blur',  () => nuiPost('setFocus', { focused: false }));
});

document.addEventListener('keydown', e => {
    if (e.key === 'Escape') {
        const overlay = document.getElementById('confirm-overlay');
        if (!overlay.classList.contains('hidden')) {
            overlay.classList.add('hidden');
            return;
        }
        nuiPost('closePanel');
    }
});

// ============================================================
// Helpers
// ============================================================

function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
}

function pad2(n) { return String(n).padStart(2, '0'); }

function setVisible(element, visible) {
    if (visible) element.classList.remove('hidden');
    else         element.classList.add('hidden');
}

// Request state as soon as the page loads inside the NUI context.
document.addEventListener('DOMContentLoaded', () => nuiPost('requestState'));
