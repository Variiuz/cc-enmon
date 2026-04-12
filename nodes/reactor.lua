-- nodes/reactor.lua
-- Extreme Reactor sensor + actuator node.
-- Polls the reactor CC port, broadcasts REACTOR_DATA, and executes
-- CMD_REACTOR_SET commands received from the Controller.
-- No auto-control logic lives here — all authority is on the Controller.
--
-- Expected config keys: node_id, channel, controller_id, shared_secret
-- Hardware: ender modem + wired connection to reactor CC port

local net  = require("lib/network")
local pmgr = require("lib/peripheral_mgr")
local runtime_panel = require("ui/runtime_panel")

local POLL_INTERVAL  = 2   -- seconds between broadcasts
local MODEM_TYPE     = "ender_modem"
-- BigReactors / Extreme Reactors exports as "BigReactors-Reactor"
-- Larger Reactors (Modern Extreme Reactors fork) uses "bigger_reactors:reactor_access_port"
-- We search for either.
local REACTOR_TYPES  = {
    "BigReactors-Reactor",
    "bigger_reactors:reactor_access_port",
    "bigreactors:reactor_access_port",
}

local reactor = {}
local runtime_ui = nil

local function updatePanel(cfg, status, detail, color)
    if not runtime_ui then return end
    runtime_ui.setSummary({
        { "Node", tostring(cfg.get("node_id")) },
        { "Channel", tostring(cfg.get("channel")) },
        { "Controller", tostring(cfg.get("controller_id") or "--") },
        { "Status", status or "Idle", color or colors.black, colors.white },
        { "Detail", detail or "--" },
    })
end

local function logLine(msg, fg)
    if runtime_ui then runtime_ui.log(msg, fg) else print(msg) end
end

local function findModem()
    local m = pmgr.find(MODEM_TYPE)
    if not m then m = pmgr.find("modem") end
    return m
end

local function findReactor()
    for _, rtype in ipairs(REACTOR_TYPES) do
        local p = pmgr.find(rtype)
        if p then return p, rtype end
    end
    return nil, nil
end

local function waitForReactor()
    logLine("[reactor] Waiting for reactor peripheral...", colors.orange)
    while true do
        local p, t = findReactor()
        if p then
            logLine("[reactor] Found: " .. t, colors.lime)
            return p
        end
        os.sleep(1)
    end
end

local function openNet(cfg)
    local modem = findModem()
    if not modem then error("No ender modem found.") end
    net.open(modem, cfg.get("channel"), cfg.get("shared_secret"), cfg.get("node_id"))
end

local function pollReactor(port)
    local active, a_err   = pmgr.call(port, "getActive")
    local produced, p_err = pmgr.call(port, "getEnergyProducedLastTick")

    if a_err then return nil, a_err end

    return {
        active          = active   == true,
        produced_last_t = produced or 0,
    }, nil
end

local function applyCommand(port, msg)
    -- CMD_REACTOR_SET payload: { active = bool }
    local want_active = msg.payload.active
    if type(want_active) ~= "boolean" then
        logLine("[reactor] Ignoring malformed CMD_REACTOR_SET (active must be bool)", colors.red)
        return
    end
    local ok, err = pmgr.call(port, "setActive", want_active)
    if not ok then
        logLine("[reactor] setActive failed: " .. tostring(err), colors.red)
    else
        logLine("[reactor] setActive(" .. tostring(want_active) .. ") OK", colors.lightBlue)
    end
end

function reactor.run(cfg)
    runtime_ui = runtime_panel.new("Reactor Node")
    runtime_ui.setHint("This node reports reactor state and listens for controller commands")
    logLine("[reactor] Starting reactor node: " .. cfg.get("node_id"), colors.lime)
    updatePanel(cfg, "Booting", "Opening network", colors.black)

    openNet(cfg)

    updatePanel(cfg, "Waiting", "Reactor peripheral", colors.orange)
    local port = waitForReactor()

    logLine("[reactor] Broadcasting every " .. POLL_INTERVAL .. "s. Listening for commands.", colors.lime)
    updatePanel(cfg, "Online", "Broadcasting every " .. POLL_INTERVAL .. "s", colors.lime)

    local consecutive_errors = 0
    local MAX_ERRORS = 10
    local timer_id = os.startTimer(POLL_INTERVAL)

    -- Run poll loop and command listener concurrently via parallel
    local function poll_loop()
        while true do
            os.pullEvent("enmon_poll")
            local data, err = pollReactor(port)
            if data then
                consecutive_errors = 0
                net.send(net.MSG.REACTOR_DATA, data)
                local detail = (data.active and "ON" or "OFF") .. "  " .. tostring(data.produced_last_t or 0) .. " RF/t"
                updatePanel(cfg, "Online", detail, colors.lime)
            else
                consecutive_errors = consecutive_errors + 1
                logLine("[reactor] Poll error (" .. consecutive_errors .. "): " .. tostring(err), colors.red)
                updatePanel(cfg, "Error", tostring(err), colors.red)
                if consecutive_errors >= MAX_ERRORS then
                    logLine("[reactor] Reconnecting...", colors.orange)
                    updatePanel(cfg, "Waiting", "Reconnecting reactor", colors.orange)
                    port = waitForReactor()
                    consecutive_errors = 0
                    updatePanel(cfg, "Online", "Reconnected", colors.lime)
                end
            end
        end
    end

    local function timer_loop()
        while true do
            local _, id = os.pullEvent("timer")
            if id == timer_id then
                os.queueEvent("enmon_poll")
                timer_id = os.startTimer(POLL_INTERVAL)
            end
        end
    end

    local function cmd_loop()
        while true do
            local msg, _ = net.receive(nil, {net.MSG.CMD_REACTOR_SET})
            if msg then
                -- Only accept commands from the configured controller
                local ctrl_id = cfg.get("controller_id")
                if ctrl_id == nil or msg.sender_id == ctrl_id then
                    applyCommand(port, msg)
                else
                    logLine("[reactor] Ignoring CMD from unknown sender: " .. tostring(msg.sender_id), colors.red)
                end
            end
        end
    end

    -- parallel.waitForAll keeps all three coroutines running; if one errors
    -- the others terminate, and the error propagates up to enmon.lua's pcall.
    parallel.waitForAll(timer_loop, poll_loop, cmd_loop)
end

return reactor
