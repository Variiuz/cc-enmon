-- nodes/display.lua
-- Display node: listens for DISPLAY_UPDATE from the Controller and renders
-- the read-only HUD on an attached monitor.
--
-- Expected config keys: node_id, channel, shared_secret, monitor_side

local net  = require("lib/network")
local identity = require("lib/node_identity")
local pmgr = require("lib/peripheral_mgr")
local hud  = require("ui/display_hud")
local runtime_panel = require("ui/runtime_panel")
local runtime_actions = require("lib/runtime_actions")
local update_service = require("lib/update_service")

local MODEM_TYPE = "ender_modem"

local display = {}

function display.run(cfg)
    local runtime_ui = runtime_panel.new("Display Node")
    local function logLine(msg, fg) runtime_ui.log(msg, fg) end
    local function updatePanel(status, detail, color)
        runtime_ui.setSummary({
            { "Node", tostring(cfg.get("node_id")) },
            { "Channel", tostring(cfg.get("channel")) },
            { "Monitor", tostring(cfg.get("monitor_side")) },
            { "Status", status, color or colors.black, colors.white },
            { "Detail", detail or "--" },
        })
    end

    runtime_ui.setHint("F2 Config")
    logLine("[display] Starting display node: " .. cfg.get("node_id"), colors.lime)
    updatePanel("Booting", "Opening network", colors.black)

    local modem = pmgr.find(MODEM_TYPE) or pmgr.find("modem")
    if not modem then error("No ender modem found.") end
    net.open(modem, cfg.get("channel"), cfg.get("shared_secret"), cfg.get("node_id"))

    local mon_side = cfg.get("monitor_side")
    hud.init(mon_side)
    identity.announce(cfg, "display", "startup")
    updatePanel("Online", "Waiting for controller updates", colors.lime)

    local function net_loop()
        while true do
            local msg = net.receive(nil, { net.MSG.DISPLAY_UPDATE, net.MSG.UPDATE_CHECK, net.MSG.UPDATE_OFFER, net.MSG.UPDATE_START, net.MSG.UPDATE_ABORT })
            if msg then
                if msg.type == net.MSG.DISPLAY_UPDATE then
                    hud.update(msg.payload)
                    local detail = (msg.payload and msg.payload.timestamp) or "Update received"
                    updatePanel("Online", detail, colors.lime)
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

    local function hello_loop()
        while true do
            os.sleep(10)
            identity.announce(cfg, "display", "heartbeat")
        end
    end

    local runtime_action = nil

    local function key_loop()
        while true do
            local _, key = os.pullEvent("key")
            if runtime_ui.handleKey(key) then
            elseif key == keys.f2 then
                runtime_action = "config"
                return
            end
        end
    end

    parallel.waitForAny(net_loop, hud_loop, hello_loop, key_loop)

    if runtime_action == "config" then
        runtime_actions.openConfigEditor(cfg, logLine)
    end
end

return display
