-- nodes/pocket.lua
-- Pocket Computer monitoring node.
-- Sends POCKET_REQUEST to the Controller every 2 seconds and renders
-- the compact read-only HUD via ui/pocket_hud.lua.
--
-- Expected config keys: node_id, channel, controller_id, shared_secret

local net  = require("lib/network")
local identity = require("lib/node_identity")
local pmgr = require("lib/peripheral_mgr")
local hud  = require("ui/pocket_hud")
local update_service = require("lib/update_service")

local POLL_INTERVAL = 2
local MODEM_TYPE    = "ender_modem"

local pocket = {}

function pocket.run(cfg)
    print("[pocket] Starting pocket node: " .. cfg.get("node_id"))

    local modem = pmgr.find(MODEM_TYPE) or pmgr.find("modem")
    if not modem then error("No ender modem found.") end
    net.open(modem, cfg.get("channel"), cfg.get("shared_secret"), cfg.get("node_id"))

    hud.init()
    identity.announce(cfg, "pocket", "startup")

    local ctrl_id = cfg.get("controller_id")
    local my_id   = os.getComputerID()

    local function request_loop()
        local next_hello = os.clock() + 10
        while true do
            net.send(net.MSG.POCKET_REQUEST, identity.decorateTelemetry("pocket", { from = my_id }))
            if os.clock() >= next_hello then
                identity.announce(cfg, "pocket", "heartbeat")
                next_hello = os.clock() + 10
            end
            os.sleep(POLL_INTERVAL)
        end
    end

    local function receive_loop()
        while true do
            local msg = net.receive(POLL_INTERVAL * 3, { net.MSG.POCKET_DATA, net.MSG.UPDATE_CHECK, net.MSG.UPDATE_OFFER, net.MSG.UPDATE_START, net.MSG.UPDATE_ABORT })
            if msg then
                if msg.type == net.MSG.POCKET_DATA then
                    if msg.payload.for_sender == nil or msg.payload.for_sender == my_id then
                        if ctrl_id == nil or msg.sender_id == ctrl_id then
                            hud.update(msg.payload)
                        end
                    end
                else
                    update_service.handleMessage(cfg, msg, print)
                end
            end
        end
    end

    local function hud_loop()
        hud.run()
    end

    parallel.waitForAll(request_loop, receive_loop, hud_loop)
end

return pocket
