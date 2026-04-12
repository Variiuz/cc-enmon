-- nodes/matrix.lua
-- Induction Matrix sensor node.
-- Wraps the Mekanism induction_port peripheral, polls data every 2 seconds,
-- and broadcasts MATRIX_DATA to the network.
--
-- Expected config keys: node_id, channel, shared_secret
-- Hardware: ender modem + wired connection to induction_port

local net  = require("lib/network")
local identity = require("lib/node_identity")
local pmgr = require("lib/peripheral_mgr")
local update_service = require("lib/update_service")
local util = require("lib/util")
local runtime_panel = require("ui/runtime_panel")

local POLL_INTERVAL = 2   -- seconds between broadcasts
local MODEM_TYPE    = "ender_modem"
-- Known peripheral type strings for Mekanism induction port across versions
local MATRIX_TYPES  = {
    "mekanism:induction_port",
    "inductionPort",
    "mekanism.induction_port",
}

local matrix = {}
local runtime_ui = nil

local function updatePanel(cfg, status, detail, color)
    if not runtime_ui then return end
    runtime_ui.setSummary({
        { "Node", tostring(cfg.get("node_id")) },
        { "Channel", tostring(cfg.get("channel")) },
        { "Computer", tostring(os.getComputerID()) },
        { "Status", status or "Idle", color or colors.black, colors.white },
        { "Detail", detail or "--" },
    })
end

local function logLine(msg, fg)
    if runtime_ui then runtime_ui.log(msg, fg) else print(msg) end
end

-- Try each known type string, validating the peripheral actually responds.
-- Falls back to scanning all peripherals for any with the Mekanism energy API.
local function findInductionPort()
    for _, t in ipairs(MATRIX_TYPES) do
        local p = pmgr.find(t)
        -- Confirm it actually responds (peripheral.find can return stale entries)
        if p and pcall(p.getEnergy, p) then return p end
    end
    -- Method-based fallback: scan everything, require getEnergy + some capacity method
    for _, name in ipairs(peripheral.getNames()) do
        local ok, p = pcall(peripheral.wrap, name)
        if ok and p and type(p.getEnergy) == "function" then
            local has_cap = type(p.getMaxEnergy)      == "function"
                         or type(p.getEnergyCapacity) == "function"
            local responds = pcall(p.getEnergy, p)
            if has_cap and responds then
                logLine("[matrix] Found induction port via method scan: " .. name, colors.lightBlue)
                return p
            end
        end
    end
    return nil
end

local function waitForPort()
    while true do
        local p = findInductionPort()
        if p then return p end
        os.sleep(1)
    end
end

local function findModem()
    local m = pmgr.find(MODEM_TYPE)
    if not m then
        -- Fallback: any wireless modem
        m = pmgr.find("modem")
    end
    return m
end

local function openNet(cfg)
    local modem = findModem()
    if not modem then
        error("No ender modem found. Attach one and reboot.")
    end
    net.open(modem, cfg.get("channel"), cfg.get("shared_secret"), cfg.get("node_id"))
end

local function pollMatrix(port)
    -- Energy stored — required
    local energy, e_err = pmgr.call(port, "getEnergy")
    if e_err then return nil, e_err end

    -- Max capacity: Mekanism <10 uses getMaxEnergy, >=10 uses getEnergyCapacity
    local maxEnergy = pmgr.call(port, "getMaxEnergy")
    if maxEnergy == nil then
        maxEnergy = pmgr.call(port, "getEnergyCapacity")
    end

    -- I/O rates: soft-fail if absent in this modpack version
    local lastInput  = pmgr.call(port, "getLastInput")  or 0
    local lastOutput = pmgr.call(port, "getLastOutput") or 0

    return {
        energy      = energy     or 0,
        max_energy  = maxEnergy  or 0,
        last_input  = lastInput,
        last_output = lastOutput,
    }, nil
end

function matrix.run(cfg)
    runtime_ui = runtime_panel.new("Matrix Node")
    runtime_ui.setHint("F3 logs. This terminal shows runtime status; matrix data is sent over network")
    logLine("[matrix] Starting matrix node: " .. cfg.get("node_id"), colors.lime)
    updatePanel(cfg, "Booting", "Opening network", colors.black)

    openNet(cfg)
    identity.announce(cfg, "matrix", "startup")

    -- Wait for the induction port to become available
    logLine("[matrix] Waiting for induction port...", colors.orange)
    updatePanel(cfg, "Waiting", "Induction port", colors.orange)
    local port = waitForPort()
    if not port then
        error("Induction port not found.")
    end
    logLine("[matrix] Induction port connected. Broadcasting every " .. POLL_INTERVAL .. "s.", colors.lime)
    updatePanel(cfg, "Online", "Broadcasting every " .. POLL_INTERVAL .. "s", colors.lime)

    local consecutive_errors = 0
    local MAX_ERRORS = 10

    local function poll_loop()
        while true do
            local data, err = pollMatrix(port)

            if data then
                consecutive_errors = 0
                data = identity.decorateTelemetry("matrix", data)
                net.send(net.MSG.MATRIX_DATA, data)
                updatePanel(cfg, "Online", util.formatPercent(util.fillFraction(data.energy, data.max_energy)), colors.lime)
            else
                consecutive_errors = consecutive_errors + 1
                logLine("[matrix] Poll error (" .. consecutive_errors .. "): " .. tostring(err), colors.red)
                updatePanel(cfg, "Error", tostring(err), colors.red)

                if consecutive_errors >= MAX_ERRORS then
                    logLine("[matrix] Too many errors - waiting for induction port to reconnect...", colors.orange)
                    updatePanel(cfg, "Waiting", "Reconnecting induction port", colors.orange)
                    port = waitForPort()
                    if port then
                        consecutive_errors = 0
                        logLine("[matrix] Reconnected.", colors.lime)
                        updatePanel(cfg, "Online", "Reconnected", colors.lime)
                    end
                end
            end

            os.sleep(POLL_INTERVAL)
        end
    end

    local function command_loop()
        while true do
            local msg = net.receive(nil, { net.MSG.UPDATE_CHECK, net.MSG.UPDATE_OFFER, net.MSG.UPDATE_START, net.MSG.UPDATE_ABORT })
            if msg then
                update_service.handleMessage(cfg, msg, function(message)
                    logLine(message, colors.lightBlue)
                end)
            end
        end
    end

    local function key_loop()
        while true do
            local _, key = os.pullEvent("key")
            runtime_ui.handleKey(key)
        end
    end

    parallel.waitForAll(poll_loop, command_loop, key_loop)
end

return matrix
