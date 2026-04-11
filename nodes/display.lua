-- nodes/display.lua
-- Display node: listens for DISPLAY_UPDATE from the Controller and renders
-- the read-only HUD on an attached monitor.
--
-- Expected config keys: node_id, channel, shared_secret, monitor_side

local net  = require("lib/network")
local pmgr = require("lib/peripheral_mgr")
local hud  = require("ui/display_hud")

local MODEM_TYPE = "ender_modem"

local display = {}

function display.run(cfg)
    print("[display] Starting display node: " .. cfg.get("node_id"))

    local modem = pmgr.find(MODEM_TYPE) or pmgr.find("modem")
    if not modem then error("No ender modem found.") end
    net.open(modem, cfg.get("channel"), cfg.get("shared_secret"), cfg.get("node_id"))

    local mon_side = cfg.get("monitor_side")
    hud.init(mon_side)

    local function net_loop()
        while true do
            local msg = net.receive(nil, {net.MSG.DISPLAY_UPDATE})
            if msg then
                hud.update(msg.payload)
            end
        end
    end

    local function hud_loop()
        hud.run()
    end

    parallel.waitForAll(net_loop, hud_loop)
end

return display
