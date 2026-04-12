-- nodes/pocket/init.lua
-- Pocket Computer monitoring node.
-- Sends POCKET_REQUEST to the Controller every 2 seconds and renders
-- the compact read-only HUD via ui/pocket_hud.lua.
--
-- Expected config keys: node_id, channel, optional adopted controller linkage

local net  = require("lib/network")
local controller_link = require("lib/controller_link")
local identity = require("lib/node_identity")
local pocket_link = require("lib/pocket_link")
local pmgr = require("lib/peripheral_mgr")
local hud  = require("ui/pocket_hud")
local update_service = require("lib/update_service")

local POLL_INTERVAL = 2
local MODEM_TYPE    = "ender_modem"

local pocket = {}

function pocket.run(cfg)
    local claim_code = controller_link.newClaimCode()
    print("[pocket] Starting pocket node: " .. cfg.get("node_id"))

    local modem = pmgr.findPreferred(cfg.get("modem_side"), MODEM_TYPE, "modem")
    if not modem then error("No ender modem found.") end
    controller_link.openNodeNetwork(cfg, modem)

    hud.init()
    identity.announce(cfg, "pocket", controller_link.isAdopted(cfg) and "startup" or "unlinked", { claim_code = claim_code })

    local my_id   = os.getComputerID()

    local function request_loop()
        local next_hello = os.clock() + 10
        while true do
            local payload = pocket_link.buildRequestPayload(cfg, my_id)
            if payload then
                controller_link.sendNodeMessage(cfg, net.MSG.POCKET_REQUEST, payload)
            end
            if os.clock() >= next_hello then
                identity.announce(cfg, "pocket", controller_link.isAdopted(cfg) and "heartbeat" or "unlinked", { claim_code = claim_code })
                next_hello = os.clock() + 10
            end
            os.sleep(POLL_INTERVAL)
        end
    end

    local function receive_loop()
        while true do
            local msg = net.receive(POLL_INTERVAL * 3, { net.MSG.POCKET_DATA, net.MSG.ADOPT_REQUEST, net.MSG.UPDATE_CHECK, net.MSG.UPDATE_OFFER, net.MSG.UPDATE_START, net.MSG.UPDATE_ABORT })
            if msg then
                if controller_link.handleAdoptRequest(cfg, msg, claim_code, print, function()
                    identity.announce(cfg, "pocket", "adopted")
                end) then
                elseif msg.type == net.MSG.POCKET_DATA then
                    if pocket_link.acceptPayload(msg.payload, my_id) then
                        if controller_link.validateControllerMessage(cfg, msg, print) then
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
