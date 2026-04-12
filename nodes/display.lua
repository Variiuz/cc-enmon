-- nodes/display.lua
-- Display node: listens for DISPLAY_UPDATE from the Controller and renders
-- the read-only HUD on an attached monitor.
--
-- Expected config keys: node_id, channel, monitor_side, optional adopted controller linkage

local net  = require("lib/network")
local controller_link = require("lib/controller_link")
local identity = require("lib/node_identity")
local pmgr = require("lib/peripheral_mgr")
local hud  = require("ui/display_hud")
local runtime_panel = require("ui/runtime_panel")
local runtime_actions = require("lib/runtime_actions")
local update_service = require("lib/update_service")
local version = require("lib/version")

local MODEM_TYPE = "ender_modem"

local display = {}
local BRANCH = version.getBranchLabel()

function display.run(cfg)
    local claim_code = controller_link.newClaimCode()
    local runtime_ui = runtime_panel.new("Display Node")
    local function logLine(msg, fg) runtime_ui.log(msg, fg) end
    local function updatePanel(status, detail, color)
        runtime_ui.setSummary({
            { "Node", tostring(cfg.get("node_id")) },
            { "Version", tostring(version.getVersion()) },
            { "Branch", tostring(BRANCH) },
            { "Channel", tostring(cfg.get("channel")) },
            { "Modem", tostring(cfg.get("modem_side") or "auto") },
            { "Monitor", tostring(cfg.get("monitor_side")) },
            { "Status", status, color or colors.black, colors.white },
            { "Detail", detail or "--" },
        })
    end

    runtime_ui.setHint("C Config")
    logLine("[display] Starting display node: " .. cfg.get("node_id"), colors.lime)
    updatePanel("Booting", "Opening network", colors.black)

    local modem = pmgr.findPreferred(cfg.get("modem_side"), MODEM_TYPE, "modem")
    if not modem then error("No ender modem found.") end
    controller_link.openNodeNetwork(cfg, modem)

    local mon_side = cfg.get("monitor_side")
    hud.init(mon_side)
    identity.announce(cfg, "display", controller_link.isAdopted(cfg) and "startup" or "unlinked", { claim_code = claim_code })
    updatePanel(controller_link.isAdopted(cfg) and "Online" or "Unlinked", controller_link.isAdopted(cfg) and "Waiting for controller updates" or ("Claim " .. claim_code), controller_link.isAdopted(cfg) and colors.lime or colors.orange)

    local function net_loop()
        while true do
            local msg = net.receive(nil, { net.MSG.DISPLAY_UPDATE, net.MSG.ADOPT_REQUEST, net.MSG.UPDATE_CHECK, net.MSG.UPDATE_OFFER, net.MSG.UPDATE_START, net.MSG.UPDATE_ABORT })
            if msg then
                if controller_link.handleAdoptRequest(cfg, msg, claim_code, function(message)
                    logLine(message, colors.lightBlue)
                end, function()
                    identity.announce(cfg, "display", "adopted")
                    updatePanel("Adopted", "Waiting for controller updates", colors.lime)
                end) then
                elseif msg.type == net.MSG.DISPLAY_UPDATE then
                    if controller_link.validateControllerMessage(cfg, msg, logLine) then
                        hud.update(msg.payload)
                        local detail = (msg.payload and msg.payload.timestamp) or "Update received"
                        updatePanel("Online", detail, colors.lime)
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

    local function hello_loop()
        while true do
            os.sleep(10)
            identity.announce(cfg, "display", controller_link.isAdopted(cfg) and "heartbeat" or "unlinked", { claim_code = claim_code })
        end
    end

    local runtime_action = nil

    local function key_loop()
        while true do
            local _, key = os.pullEvent("key")
            if runtime_ui.handleKey(key) then
            elseif key == keys.c then
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
