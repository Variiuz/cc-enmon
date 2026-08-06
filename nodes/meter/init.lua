-- nodes/meter/init.lua
-- Energy meter / current-transformer sensor node.
-- Polls Almost Reliable Energy Meter or IE current transformer and publishes METER_DATA.

local net  = require("lib/network")
local controller_link = require("lib/controller_link")
local identity = require("lib/node_identity")
local pmgr = require("lib/peripheral_mgr")
local runtime_actions = require("lib/runtime_actions")
local update_service = require("lib/update_service")
local node_runtime = require("lib/node_runtime")
local util = require("lib/util")
local meter_peripheral = require("nodes/meter/peripheral")

local POLL_INTERVAL = 2
local MODEM_TYPE    = "ender_modem"

local meter = {}

local function findModem(cfg)
    return pmgr.findPreferred(cfg.get("modem_side"), MODEM_TYPE, "modem")
end

local function openNet(cfg, claim_code)
    local modem = findModem(cfg)
    if not modem then
        error("No ender modem found. Attach one and reboot.")
    end
    controller_link.openNodeNetwork(cfg, modem, claim_code)
end

function meter.run(cfg)
    local claim_code = controller_link.isAdopted(cfg) and nil or controller_link.getOrCreateClaimCode()
    local runtime = node_runtime.create("Meter Node", cfg, {
        extra_rows = function()
            return {
                { "Computer", tostring(os.getComputerID()) },
            }
        end,
    })
    runtime.setHint("C Config")
    local logLine = runtime.log
    local updatePanel = runtime.updatePanel
    logLine("[meter] Starting meter node: " .. cfg.get("node_id"), colors.lime)
    if claim_code then
        logLine("[meter] Unlinked claim code (type this on the controller): " .. claim_code, colors.orange)
    end
    updatePanel("Booting", "Opening network", colors.black)

    openNet(cfg, claim_code)
    identity.announce(cfg, "meter", controller_link.isAdopted(cfg) and "startup" or "unlinked")

    updatePanel("Waiting", "Energy meter peripheral", colors.orange)
    local bound = cfg.get("bound_peripheral")
    local port, type_name = meter_peripheral.waitForMeter(logLine, bound)
    logLine("[meter] Connected (" .. tostring(type_name) .. "). Broadcasting every " .. POLL_INTERVAL .. "s.", colors.lime)
    updatePanel("Online", "Broadcasting every " .. POLL_INTERVAL .. "s", colors.lime)

    local consecutive_errors = 0
    local MAX_ERRORS = 10

    local function poll_loop()
        while true do
            local data, err = meter_peripheral.pollMeter(port)
            if data then
                consecutive_errors = 0
                data.peripheral_type = type_name
                data = identity.decorateTelemetry(cfg, "meter", data)
                if data then
                    controller_link.sendNodeMessage(cfg, net.MSG.METER_DATA, data)
                    updatePanel("Online", util.formatRate(data.rate or 0), colors.lime)
                else
                    updatePanel("Unlinked", "Claim " .. tostring(claim_code), colors.orange)
                end
            else
                consecutive_errors = consecutive_errors + 1
                logLine("[meter] Poll error (" .. consecutive_errors .. "): " .. tostring(err), colors.red)
                updatePanel("Error", tostring(err), colors.red)
                if consecutive_errors >= MAX_ERRORS then
                    updatePanel("Waiting", "Reconnecting meter", colors.orange)
                    port, type_name = meter_peripheral.waitForMeter(logLine, bound)
                    consecutive_errors = 0
                end
            end
            os.sleep(POLL_INTERVAL)
        end
    end

    local function command_loop()
        while true do
            local msg = net.receive(nil, { net.MSG.ADOPT_REQUEST, net.MSG.UPDATE_CHECK, net.MSG.UPDATE_OFFER, net.MSG.UPDATE_START, net.MSG.UPDATE_ABORT })
            if msg then
                if controller_link.handleAdoptRequest(cfg, msg, claim_code, function(message)
                    logLine(message, colors.lightBlue)
                end, function()
                    identity.announce(cfg, "meter", "adopted")
                    updatePanel("Adopted", "Controller " .. tostring(cfg.get("controller_id")), colors.lime)
                end) then
                else
                    update_service.handleMessage(cfg, msg, function(message)
                        logLine(message, colors.lightBlue)
                    end)
                end
            end
        end
    end

    local function hello_loop()
        while true do
            os.sleep(10)
            identity.announce(cfg, "meter", controller_link.isAdopted(cfg) and "heartbeat" or "unlinked")
        end
    end

    local runtime_action = nil
    local function key_loop()
        while true do
            local _, key = os.pullEvent("key")
            if runtime.handleKey(key) then
            elseif key == keys.c then
                runtime_action = "config"
                return
            end
        end
    end

    parallel.waitForAny(poll_loop, command_loop, hello_loop, key_loop)
    if runtime_action == "config" then
        runtime_actions.openConfigEditor(cfg, logLine)
    end
end

return meter
