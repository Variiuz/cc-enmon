-- nodes/generator/init.lua
-- Generic generator node (Immersive Engineering diesel / capacitors).
-- Publishes GENERATOR_DATA; accepts CMD_GENERATOR_SET for enable/disable.

local net  = require("lib/network")
local controller_link = require("lib/controller_link")
local identity = require("lib/node_identity")
local pmgr = require("lib/peripheral_mgr")
local runtime_actions = require("lib/runtime_actions")
local update_service = require("lib/update_service")
local node_runtime = require("lib/node_runtime")
local util = require("lib/util")
local gen_peripheral = require("nodes/generator/peripheral")

local POLL_INTERVAL = 2
local MODEM_TYPE    = "ender_modem"

local generator = {}

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

function generator.run(cfg)
    local claim_code = controller_link.isAdopted(cfg) and nil or controller_link.getOrCreateClaimCode()
    local runtime = node_runtime.create("Generator Node", cfg, {
        extra_rows = function()
            return {
                { "Computer", tostring(os.getComputerID()) },
            }
        end,
    })
    runtime.setHint("C Config")
    local logLine = runtime.log
    local updatePanel = runtime.updatePanel
    logLine("[generator] Starting generator node: " .. cfg.get("node_id"), colors.lime)
    if claim_code then
        logLine("[generator] Unlinked claim code (type this on the controller): " .. claim_code, colors.orange)
    end
    updatePanel("Booting", "Opening network", colors.black)

    openNet(cfg, claim_code)
    identity.announce(cfg, "generator", controller_link.isAdopted(cfg) and "startup" or "unlinked")

    updatePanel("Waiting", "Generator peripheral", colors.orange)
    local bound = cfg.get("bound_peripheral")
    local port, type_name = gen_peripheral.waitForGenerator(logLine, bound)
    logLine("[generator] Connected (" .. tostring(type_name) .. "). Broadcasting every " .. POLL_INTERVAL .. "s.", colors.lime)
    updatePanel("Online", "Broadcasting every " .. POLL_INTERVAL .. "s", colors.lime)

    local consecutive_errors = 0
    local MAX_ERRORS = 10

    local function poll_loop()
        while true do
            local data, err = gen_peripheral.pollGenerator(port)
            if data then
                consecutive_errors = 0
                data.peripheral_type = type_name
                data = identity.decorateTelemetry(cfg, "generator", data)
                if data then
                    controller_link.sendNodeMessage(cfg, net.MSG.GENERATOR_DATA, data)
                    local detail = data.active and "ON" or "OFF"
                    if data.produced_last_t and data.produced_last_t ~= 0 then
                        detail = detail .. " " .. util.formatRate(data.produced_last_t)
                    end
                    updatePanel("Online", detail, colors.lime)
                else
                    updatePanel("Unlinked", "Claim " .. tostring(claim_code), colors.orange)
                end
            else
                consecutive_errors = consecutive_errors + 1
                logLine("[generator] Poll error (" .. consecutive_errors .. "): " .. tostring(err), colors.red)
                updatePanel("Error", tostring(err), colors.red)
                if consecutive_errors >= MAX_ERRORS then
                    updatePanel("Waiting", "Reconnecting generator", colors.orange)
                    port, type_name = gen_peripheral.waitForGenerator(logLine, bound)
                    consecutive_errors = 0
                end
            end
            os.sleep(POLL_INTERVAL)
        end
    end

    local function command_loop()
        while true do
            local msg = net.receive(nil, {
                net.MSG.CMD_GENERATOR_SET,
                net.MSG.ADOPT_REQUEST,
                net.MSG.UPDATE_CHECK,
                net.MSG.UPDATE_OFFER,
                net.MSG.UPDATE_START,
                net.MSG.UPDATE_ABORT,
            })
            if msg then
                if msg.type == net.MSG.CMD_GENERATOR_SET then
                    if not controller_link.isControllerAuth(cfg, msg) then
                        logLine("[generator] Ignoring unauthenticated command from " .. tostring(msg.sender), colors.red)
                    else
                        gen_peripheral.applyCommand(port, msg.payload, logLine)
                    end
                elseif controller_link.handleAdoptRequest(cfg, msg, claim_code, function(message)
                    logLine(message, colors.lightBlue)
                end, function()
                    identity.announce(cfg, "generator", "adopted")
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
            identity.announce(cfg, "generator", controller_link.isAdopted(cfg) and "heartbeat" or "unlinked")
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

return generator
