-- nodes/reactor/init.lua
-- Extreme Reactor sensor + actuator node.
-- Polls the reactor CC port, broadcasts REACTOR_DATA, and executes
-- CMD_REACTOR_SET commands received from the Controller.
-- No auto-control logic lives here — all authority is on the Controller.
--
-- Expected config keys: node_id, channel, optional adopted controller linkage
-- Hardware: ender modem + wired connection to reactor CC port

local net  = require("lib/network")
local controller_link = require("lib/controller_link")
local identity = require("lib/node_identity")
local pmgr = require("lib/peripheral_mgr")
local runtime_actions = require("lib/runtime_actions")
local update_service = require("lib/update_service")
local node_runtime = require("lib/node_runtime")
local reactor_peripheral = require("nodes/reactor/peripheral")

local POLL_INTERVAL  = 2   -- seconds between broadcasts
local MODEM_TYPE     = "ender_modem"

local reactor = {}

local function findModem(cfg)
    return pmgr.findPreferred(cfg.get("modem_side"), MODEM_TYPE, "modem")
end

local function openNet(cfg, claim_code)
    local modem = findModem(cfg)
    if not modem then error("No ender modem found.") end
    controller_link.openNodeNetwork(cfg, modem, claim_code)
end

function reactor.run(cfg)
    local claim_code = controller_link.isAdopted(cfg) and nil or controller_link.getOrCreateClaimCode()
    local runtime = node_runtime.create("Reactor Node", cfg, {
        extra_rows = function(local_cfg)
            return {
                { "Controller", tostring(local_cfg.get("controller_id") or "--") },
            }
        end,
    })
    runtime.setHint("C Config")
    local logLine = runtime.log
    local updatePanel = runtime.updatePanel
    logLine("[reactor] Starting reactor node: " .. cfg.get("node_id"), colors.lime)
    if claim_code then
        logLine("[reactor] Unlinked claim code (type this on the controller): " .. claim_code, colors.orange)
    end
    updatePanel("Booting", "Opening network", colors.black)

    openNet(cfg, claim_code)
    identity.announce(cfg, "reactor", controller_link.isAdopted(cfg) and "startup" or "unlinked")

    updatePanel("Waiting", "Reactor peripheral", colors.orange)
    local bound = cfg.get("bound_peripheral")
    local port = reactor_peripheral.waitForReactor(logLine, bound)

    logLine("[reactor] Broadcasting every " .. POLL_INTERVAL .. "s. Listening for commands.", colors.lime)
    updatePanel("Online", "Broadcasting every " .. POLL_INTERVAL .. "s", colors.lime)

    local consecutive_errors = 0
    local MAX_ERRORS = 10
    local timer_id = os.startTimer(POLL_INTERVAL)

    -- Run poll loop and command listener concurrently via parallel
    local function poll_loop()
        while true do
            os.pullEvent("enmon_poll")
            local data, err = reactor_peripheral.pollReactor(port)
            if data then
                consecutive_errors = 0
                data = identity.decorateTelemetry(cfg, "reactor", data)
                if data then
                    controller_link.sendNodeMessage(cfg, net.MSG.REACTOR_DATA, data)
                    local detail = (data.active and "ON" or "OFF") .. "  " .. tostring(data.produced_last_t or 0) .. " RF/t"
                    if data.control_rod_level ~= nil then
                        detail = detail .. "  Rod " .. tostring(math.floor((data.control_rod_level or 0) + 0.5)) .. "%"
                    end
                    updatePanel("Online", detail, colors.lime)
                else
                    updatePanel("Unlinked", "Claim " .. claim_code, colors.orange)
                end
            else
                consecutive_errors = consecutive_errors + 1
                logLine("[reactor] Poll error (" .. consecutive_errors .. "): " .. tostring(err), colors.red)
                updatePanel("Error", tostring(err), colors.red)
                if consecutive_errors >= MAX_ERRORS then
                    logLine("[reactor] Reconnecting...", colors.orange)
                    updatePanel("Waiting", "Reconnecting reactor", colors.orange)
                    port = reactor_peripheral.waitForReactor(logLine, bound)
                    consecutive_errors = 0
                    updatePanel("Online", "Reconnected", colors.lime)
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
            local msg, _ = net.receive(nil, { net.MSG.CMD_REACTOR_SET, net.MSG.ADOPT_REQUEST, net.MSG.UPDATE_CHECK, net.MSG.UPDATE_OFFER, net.MSG.UPDATE_START, net.MSG.UPDATE_ABORT })
            if msg then
                if controller_link.handleAdoptRequest(cfg, msg, claim_code, function(message)
                    logLine(message, colors.lightBlue)
                end, function()
                    identity.announce(cfg, "reactor", "adopted")
                    updatePanel("Adopted", "Controller " .. tostring(cfg.get("controller_id")), colors.lime)
                end) then
                elseif msg.type == net.MSG.CMD_REACTOR_SET then
                    if controller_link.validateControllerMessage(cfg, msg, logLine) then
                        reactor_peripheral.applyCommand(port, msg.payload, logLine)
                    else
                        logLine("[reactor] Ignoring CMD from unknown sender: " .. tostring(msg.sender_id), colors.red)
                    end
                else
                    update_service.handleMessage(cfg, msg, function(message)
                        logLine(message, colors.lightBlue)
                    end)
                end
            end
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

    local function hello_loop()
        while true do
            os.sleep(10)
            identity.announce(cfg, "reactor", controller_link.isAdopted(cfg) and "heartbeat" or "unlinked")
        end
    end

    -- parallel.waitForAll keeps all three coroutines running; if one errors
    -- the others terminate, and the error propagates up to enmon.lua's pcall.
    parallel.waitForAny(timer_loop, poll_loop, cmd_loop, hello_loop, key_loop)

    if runtime_action == "config" then
        runtime_actions.openConfigEditor(cfg, logLine)
    end
end

return reactor
