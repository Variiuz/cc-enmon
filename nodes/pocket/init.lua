-- nodes/pocket/init.lua
-- Pocket Computer monitoring + remote control node.
-- Sends POCKET_REQUEST / POCKET_CMD to the Controller and renders ui/pocket_hud.lua.

local net  = require("lib/network")
local controller_link = require("lib/controller_link")
local identity = require("lib/node_identity")
local pocket_link = require("lib/pocket_link")
local pmgr = require("lib/peripheral_mgr")
local hud  = require("ui/pocket_hud")
local update_service = require("lib/update_service")
local runtime_actions = require("lib/runtime_actions")
local node_runtime = require("lib/node_runtime")

local POLL_INTERVAL = 2
local MODEM_TYPE    = "ender_modem"

local pocket = {}

function pocket.run(cfg)
    local claim_code = controller_link.isAdopted(cfg) and nil or controller_link.getOrCreateClaimCode()
    local runtime = node_runtime.create("Pocket Node", cfg, {
        extra_rows = function(local_cfg)
            return {
                { "Controller", tostring(local_cfg.get("controller_id") or "--") },
            }
        end,
    })
    runtime.setHint("C Config | F3 Log")
    local logLine = runtime.log
    local updatePanel = runtime.updatePanel

    logLine("[pocket] Starting pocket node: " .. cfg.get("node_id"), colors.lime)
    if claim_code then
        logLine("[pocket] Unlinked claim code (type this on the controller): " .. claim_code, colors.orange)
    end
    updatePanel(controller_link.isAdopted(cfg) and "Booting" or "Unlinked", claim_code and ("Claim " .. claim_code) or "Opening network", claim_code and colors.orange or colors.black)

    local modem = pmgr.findPreferred(cfg.get("modem_side"), MODEM_TYPE, "modem")
    if not modem then error("No ender modem found.") end
    controller_link.openNodeNetwork(cfg, modem, claim_code)

    local pending_cmds = {}
    hud.setCommandHandler(function(payload)
        pending_cmds[#pending_cmds + 1] = payload
    end)
    hud.init()
    identity.announce(cfg, "pocket", controller_link.isAdopted(cfg) and "startup" or "unlinked")
    updatePanel(controller_link.isAdopted(cfg) and "Online" or "Unlinked", claim_code and ("Claim " .. claim_code) or "Waiting for controller", claim_code and colors.orange or colors.lime)

    local my_id = os.getComputerID()
    local runtime_action = nil

    local function request_loop()
        local next_hello = os.clock() + 10
        while true do
            while #pending_cmds > 0 do
                local cmd = table.remove(pending_cmds, 1)
                local payload = pocket_link.buildRequestPayload(cfg, my_id) or {}
                for key, value in pairs(cmd or {}) do
                    payload[key] = value
                end
                controller_link.sendNodeMessage(cfg, net.MSG.POCKET_CMD, payload)
                logLine("[pocket] CMD " .. tostring(cmd.action) .. " -> " .. tostring(cmd.target_node_id), colors.lightBlue)
            end

            local payload = pocket_link.buildRequestPayload(cfg, my_id)
            if payload then
                controller_link.sendNodeMessage(cfg, net.MSG.POCKET_REQUEST, payload)
            end
            if os.clock() >= next_hello then
                identity.announce(cfg, "pocket", controller_link.isAdopted(cfg) and "heartbeat" or "unlinked")
                next_hello = os.clock() + 10
            end
            os.sleep(POLL_INTERVAL)
        end
    end

    local function receive_loop()
        while true do
            local msg = net.receive(POLL_INTERVAL * 3, { net.MSG.POCKET_DATA, net.MSG.ADOPT_REQUEST, net.MSG.UPDATE_CHECK, net.MSG.UPDATE_OFFER, net.MSG.UPDATE_START, net.MSG.UPDATE_ABORT })
            if msg then
                if controller_link.handleAdoptRequest(cfg, msg, claim_code, function(message)
                    logLine(message, colors.lightBlue)
                end, function()
                    identity.announce(cfg, "pocket", "adopted")
                    updatePanel("Adopted", "Controller " .. tostring(cfg.get("controller_id")), colors.lime)
                end) then
                elseif msg.type == net.MSG.POCKET_DATA then
                    if pocket_link.acceptPayload(msg.payload, my_id) then
                        if controller_link.validateControllerMessage(cfg, msg, logLine) then
                            hud.update(msg.payload)
                            updatePanel("Online", (msg.payload and msg.payload.timestamp) or "Update received", colors.lime)
                        end
                    end
                else
                    update_service.handleMessage(cfg, msg, function(message)
                        logLine(message, colors.lightBlue)
                    end)
                end
            end
        end
    end

    local function hud_loop()
        hud.run()
    end

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

    parallel.waitForAny(request_loop, receive_loop, hud_loop, key_loop)

    if runtime_action == "config" then
        runtime_actions.openConfigEditor(cfg, logLine)
    end
end

return pocket
