-- nodes/matrix/init.lua
-- Induction Matrix sensor node.
-- Wraps the Mekanism induction_port peripheral, polls data every 2 seconds,
-- and broadcasts MATRIX_DATA to the network.
--
-- Expected config keys: node_id, channel, optional adopted controller linkage
-- Hardware: ender modem + wired connection to induction_port

local net  = require("lib/network")
local controller_link = require("lib/controller_link")
local identity = require("lib/node_identity")
local pmgr = require("lib/peripheral_mgr")
local runtime_actions = require("lib/runtime_actions")
local update_service = require("lib/update_service")
local node_runtime = require("lib/node_runtime")
local util = require("lib/util")
local matrix_peripheral = require("nodes/matrix/peripheral")

local POLL_INTERVAL = 2   -- seconds between broadcasts
local MODEM_TYPE    = "ender_modem"

local matrix = {}

local function findModem(cfg)
    return pmgr.findPreferred(cfg.get("modem_side"), MODEM_TYPE, "modem")
end

local function openNet(cfg)
    local modem = findModem(cfg)
    if not modem then
        error("No ender modem found. Attach one and reboot.")
    end
    controller_link.openNodeNetwork(cfg, modem)
end

function matrix.run(cfg)
    local claim_code = controller_link.newClaimCode()
    local runtime = node_runtime.create("Matrix Node", cfg, {
        extra_rows = function()
            return {
                { "Computer", tostring(os.getComputerID()) },
            }
        end,
    })
    runtime.setHint("C Config")
    local logLine = runtime.log
    local updatePanel = runtime.updatePanel
    logLine("[matrix] Starting matrix node: " .. cfg.get("node_id"), colors.lime)
    updatePanel("Booting", "Opening network", colors.black)

    openNet(cfg)
    identity.announce(cfg, "matrix", controller_link.isAdopted(cfg) and "startup" or "unlinked", { claim_code = claim_code })

    -- Wait for the induction port to become available
    logLine("[matrix] Waiting for induction port...", colors.orange)
    updatePanel("Waiting", "Induction port", colors.orange)
    local port = matrix_peripheral.waitForPort(logLine)
    if not port then
        error("Induction port not found.")
    end
    logLine("[matrix] Induction port connected. Broadcasting every " .. POLL_INTERVAL .. "s.", colors.lime)
    updatePanel("Online", "Broadcasting every " .. POLL_INTERVAL .. "s", colors.lime)

    local consecutive_errors = 0
    local MAX_ERRORS = 10

    local function poll_loop()
        while true do
            local data, err = matrix_peripheral.pollMatrix(port)

            if data then
                consecutive_errors = 0
                data = identity.decorateTelemetry(cfg, "matrix", data)
                if data then
                    controller_link.sendNodeMessage(cfg, net.MSG.MATRIX_DATA, data)
                    updatePanel("Online", util.formatPercent(util.fillFraction(data.energy, data.max_energy)), colors.lime)
                else
                    updatePanel("Unlinked", "Claim " .. claim_code, colors.orange)
                end
            else
                consecutive_errors = consecutive_errors + 1
                logLine("[matrix] Poll error (" .. consecutive_errors .. "): " .. tostring(err), colors.red)
                updatePanel("Error", tostring(err), colors.red)

                if consecutive_errors >= MAX_ERRORS then
                    logLine("[matrix] Too many errors - waiting for induction port to reconnect...", colors.orange)
                    updatePanel("Waiting", "Reconnecting induction port", colors.orange)
                    port = matrix_peripheral.waitForPort(logLine)
                    if port then
                        consecutive_errors = 0
                        logLine("[matrix] Reconnected.", colors.lime)
                        updatePanel("Online", "Reconnected", colors.lime)
                    end
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
                    identity.announce(cfg, "matrix", "adopted")
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
            identity.announce(cfg, "matrix", controller_link.isAdopted(cfg) and "heartbeat" or "unlinked", { claim_code = claim_code })
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

return matrix
