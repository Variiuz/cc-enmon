-- nodes/controller.lua
-- Central authority node.
-- - Receives MATRIX_DATA and REACTOR_DATA from sensor nodes
-- - Evaluates auto-control thresholds and sends CMD_REACTOR_SET
-- - Broadcasts DISPLAY_UPDATE to display nodes
-- - Responds to POCKET_REQUEST with POCKET_DATA
-- - Drives the controller HUD via ui/controller_hud.lua
-- - Fires speaker alerts when conditions are met

local net  = require("lib/network")
local pmgr = require("lib/peripheral_mgr")
local util = require("lib/util")
local hud  = require("ui/controller_hud")
local runtime_panel = require("ui/runtime_panel")

local MODEM_TYPE     = "ender_modem"
local DISPLAY_INTERVAL = 1  -- seconds between DISPLAY_UPDATE broadcasts
local STALE_TIMEOUT    = 10 -- seconds before a node is marked disconnected

local controller = {}
local runtime_ui = nil

-- ── State ───────────────────────────────────────────────────────────────────────
-- matrix_state: latest data from any matrix node
-- reactors: table keyed by node_id, each entry holds latest reactor data + timestamps
-- alerts: table of active alert strings
local state = {
    matrix  = nil,
    matrix_updated = 0,
    reactors = {},
    alerts   = {},
}

-- ── Helpers ─────────────────────────────────────────────────────────────────────
local function now() return os.clock() end

local function logLine(msg, fg)
    if runtime_ui then
        runtime_ui.log(msg, fg)
    else
        print(msg)
    end
end

local function isStale(timestamp)
    return (now() - timestamp) > STALE_TIMEOUT
end

local function updateAlerts(cfg)
    local new_alerts = {}

    -- Matrix stale / disconnected
    if state.matrix == nil or isStale(state.matrix_updated) then
        new_alerts[#new_alerts+1] = "MATRIX: No data"
    else
        local fill = util.fillFraction(state.matrix.energy, state.matrix.max_energy)
        if fill <= cfg.get("threshold_low") then
            new_alerts[#new_alerts+1] = "ENERGY LOW: " .. util.formatPercent(fill)
        elseif fill >= cfg.get("threshold_high") then
            new_alerts[#new_alerts+1] = "ENERGY HIGH: " .. util.formatPercent(fill)
        end
    end

    -- Reactor disconnected
    for nid, r in pairs(state.reactors) do
        if isStale(r.updated) then
            new_alerts[#new_alerts+1] = "REACTOR " .. nid .. ": No data"
        end
    end

    state.alerts = new_alerts
end

local function playAlerts(speaker, cfg)
    if not speaker then return end
    if #state.alerts > 0 then
        pcall(speaker.playNote, speaker, "harp", 1, 6)
    end
end

-- Auto-control: send CMD_REACTOR_SET to all known reactor nodes.
local function autoControl(cfg)
    if not cfg.get("auto_ctrl") then return end
    if state.matrix == nil or isStale(state.matrix_updated) then return end

    local fill = util.fillFraction(state.matrix.energy, state.matrix.max_energy)
    local lo   = cfg.get("threshold_low")
    local hi   = cfg.get("threshold_high")

    local want_active = nil
    if fill <= lo then
        want_active = true
    elseif fill >= hi then
        want_active = false
    end

    if want_active == nil then return end

    for nid, r in pairs(state.reactors) do
        if not isStale(r.updated) and r.active ~= want_active then
            net.send(net.MSG.CMD_REACTOR_SET, { active = want_active })
            r.pending_active = want_active
            logLine("[ctrl] auto-ctrl: reactor " .. nid ..
                  " -> " .. tostring(want_active) ..
                  " (fill " .. util.formatPercent(fill) .. ")", colors.lightBlue)
        end
    end
end

-- Build DISPLAY_UPDATE payload from current state.
local function buildDisplayPayload()
    return {
        matrix   = state.matrix,
        matrix_stale = (state.matrix == nil or isStale(state.matrix_updated)),
        reactors = state.reactors,
        alerts   = state.alerts,
        timestamp = util.timestamp(),
    }
end

local function refreshPanel(cfg)
    if not runtime_ui then return end

    local reactor_count = 0
    for _ in pairs(state.reactors) do reactor_count = reactor_count + 1 end

    local matrix_status = "Waiting"
    local matrix_fg = colors.black
    local matrix_bg = colors.white
    if state.matrix and not isStale(state.matrix_updated) then
        matrix_status = util.formatPercent(util.fillFraction(state.matrix.energy, state.matrix.max_energy))
        matrix_fg = colors.white
        matrix_bg = colors.blue
    elseif state.matrix and isStale(state.matrix_updated) then
        matrix_status = "Stale"
        matrix_fg = colors.red
        matrix_bg = colors.white
    end

    local alert_text = (#state.alerts > 0) and state.alerts[1] or "All nominal"
    local alert_fg = (#state.alerts > 0) and colors.red or colors.black
    local alert_bg = colors.white

    runtime_ui.setSummary({
        { "Computer ID", tostring(os.getComputerID()), colors.white, colors.blue },
        { "Node", tostring(cfg.get("node_id")) },
        { "Channel", tostring(cfg.get("channel")) },
        { "Matrix", matrix_status, matrix_fg, matrix_bg },
        { "Reactors", tostring(reactor_count) },
        { "Alert", alert_text, alert_fg, alert_bg },
    })
end

-- ── Message handlers ─────────────────────────────────────────────────────────────
local function onMatrixData(msg, cfg)
    state.matrix         = msg.payload
    state.matrix_updated = now()
    updateAlerts(cfg)
    autoControl(cfg)
end

local function onReactorData(msg, cfg)
    local nid = msg.node_id
    if not state.reactors[nid] then
        state.reactors[nid] = {}
        logLine("[ctrl] New reactor node registered: " .. nid, colors.lime)
    end
    local r = state.reactors[nid]
    r.active          = msg.payload.active
    r.produced_last_t = msg.payload.produced_last_t
    r.updated         = now()
    r.node_id         = nid
    r.sender_id       = msg.sender_id
    updateAlerts(cfg)
    refreshPanel(cfg)
end

local function onPocketRequest(msg)
    local payload = buildDisplayPayload()
    -- Reply directly to the requesting computer's ID via targeted send
    -- (ender modems broadcast on a channel; we include source computer ID so
    --  the pocket node can filter its own responses)
    payload.for_sender = msg.sender_id
    net.send(net.MSG.POCKET_DATA, payload)
end

-- ── Manual reactor toggle (called from HUD) ──────────────────────────────────────
function controller.setReactorActive(node_id, active)
    net.send(net.MSG.CMD_REACTOR_SET, { active = active })
    logLine("[ctrl] manual CMD_REACTOR_SET -> " .. tostring(active) ..
          " (node: " .. tostring(node_id) .. ")", colors.lightBlue)
end

-- ── Main run loop ────────────────────────────────────────────────────────────────
function controller.run(cfg)
    runtime_ui = runtime_panel.new("Controller")
    runtime_ui.setHint("Monitor HUD runs separately on the attached monitor")
    logLine("[ctrl] Starting controller: " .. cfg.get("node_id"), colors.lime)

    -- Open network
    local modem = pmgr.find(MODEM_TYPE) or pmgr.find("modem")
    if not modem then error("No ender modem found.") end
    net.open(modem, cfg.get("channel"), cfg.get("shared_secret"), cfg.get("node_id"))

    -- Find speaker (optional)
    local speaker = nil
    local spk_side = cfg.get("speaker_side")
    if spk_side then
        speaker = pmgr.wrap(spk_side)
        if speaker then logLine("[ctrl] Speaker attached: " .. spk_side, colors.lime) end
    end
    refreshPanel(cfg)

    -- Initialise HUD (sets up Basalt on the monitor)
    local mon_side = cfg.get("monitor_side")
    hud.init(mon_side, cfg, controller)

    -- Timers
    local display_timer   = os.startTimer(DISPLAY_INTERVAL)
    local alert_timer     = os.startTimer(5)

    -- Message receive loop + HUD event loop run in parallel
    local function net_loop()
        while true do
            local msg = net.receive(DISPLAY_INTERVAL + 1, {
                net.MSG.MATRIX_DATA,
                net.MSG.REACTOR_DATA,
                net.MSG.POCKET_REQUEST,
            })
            if msg then
                if     msg.type == net.MSG.MATRIX_DATA    then onMatrixData(msg, cfg)
                elseif msg.type == net.MSG.REACTOR_DATA   then onReactorData(msg, cfg)
                elseif msg.type == net.MSG.POCKET_REQUEST then onPocketRequest(msg)
                end
                refreshPanel(cfg)
                hud.update(buildDisplayPayload())
            end
        end
    end

    local function timer_loop()
        while true do
            local _, id = os.pullEvent("timer")
            if id == display_timer then
                -- Periodic DISPLAY_UPDATE broadcast
                net.send(net.MSG.DISPLAY_UPDATE, buildDisplayPayload())
                -- Refresh staleness-based alerts
                updateAlerts(cfg)
                refreshPanel(cfg)
                hud.update(buildDisplayPayload())
                display_timer = os.startTimer(DISPLAY_INTERVAL)
            elseif id == alert_timer then
                playAlerts(speaker, cfg)
                alert_timer = os.startTimer(5)
            end
        end
    end

    -- Basalt's run() drives its own event loop. We interleave it with our
    -- network/timer loops via parallel.
    local function hud_loop()
        hud.run()
    end

    parallel.waitForAll(net_loop, timer_loop, hud_loop)
end

return controller
