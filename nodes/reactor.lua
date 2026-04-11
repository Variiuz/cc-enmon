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
    print("[reactor] Waiting for reactor peripheral...")
    while true do
        local p, t = findReactor()
        if p then
            print("[reactor] Found: " .. t)
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
        print("[reactor] Ignoring malformed CMD_REACTOR_SET (active must be bool)")
        return
    end
    local ok, err = pmgr.call(port, "setActive", want_active)
    if not ok then
        print("[reactor] setActive failed: " .. tostring(err))
    else
        print("[reactor] setActive(" .. tostring(want_active) .. ") OK")
    end
end

function reactor.run(cfg)
    print("[reactor] Starting reactor node: " .. cfg.get("node_id"))

    openNet(cfg)

    local port = waitForReactor()

    print("[reactor] Broadcasting every " .. POLL_INTERVAL .. "s. Listening for commands.")

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
            else
                consecutive_errors = consecutive_errors + 1
                print("[reactor] Poll error (" .. consecutive_errors .. "): " .. tostring(err))
                if consecutive_errors >= MAX_ERRORS then
                    print("[reactor] Reconnecting...")
                    port = waitForReactor()
                    consecutive_errors = 0
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
                    print("[reactor] Ignoring CMD from unknown sender: " .. tostring(msg.sender_id))
                end
            end
        end
    end

    -- parallel.waitForAll keeps all three coroutines running; if one errors
    -- the others terminate, and the error propagates up to enmon.lua's pcall.
    parallel.waitForAll(timer_loop, poll_loop, cmd_loop)
end

return reactor
