local net = require("lib/network")
local util = require("lib/util")

local actions = {}

function actions.new(opts)
    local state = assert(opts.state, "state is required")
    local sendToEntry = assert(opts.sendToEntry, "sendToEntry is required")
    local logLine = assert(opts.logLine, "logLine is required")
    local updates = assert(opts.updates, "updates is required")
    local getActiveConfig = assert(opts.getActiveConfig, "getActiveConfig is required")

    local api = {}

    function api.setReactorActive(node_id, active)
        local entry = state.updates.nodes[node_id]
        if entry and entry.sender_id then
            sendToEntry(entry, net.MSG.CMD_REACTOR_SET, { active = active })
        end
        if state.reactors[node_id] then
            state.reactors[node_id].pending_active = active
        end
        logLine("[ctrl] manual CMD_REACTOR_SET -> " .. tostring(active) ..
            " (node: " .. tostring(node_id) .. ")", colors.lightBlue)
    end

    function api.setReactorControlRodLevel(node_id, level)
        local normalized = tonumber(level)
        if not normalized then return end
        normalized = util.clamp(math.floor(normalized + 0.5), 0, 100)

        local entry = state.updates.nodes[node_id]
        if entry and entry.sender_id then
            sendToEntry(entry, net.MSG.CMD_REACTOR_SET, { control_rod_level = normalized })
        end
        if state.reactors[node_id] then
            state.reactors[node_id].pending_control_rod_level = normalized
        end
        logLine("[ctrl] manual control rods -> " .. tostring(normalized) .. "% (node: " .. tostring(node_id) .. ")", colors.lightBlue)
    end

    function api.adjustReactorControlRod(node_id, delta)
        local reactor = state.reactors[node_id]
        if not reactor then return end
        local current = tonumber(reactor.control_rod_level)
        if current == nil then return end
        api.setReactorControlRodLevel(node_id, current + (tonumber(delta) or 0))
    end

    function api.requestUpdateCheck()
        local active_cfg = getActiveConfig()
        if active_cfg then updates.performUpdateCheck(active_cfg, false) end
    end

    function api.offerUpdates(node_id)
        local active_cfg = getActiveConfig()
        if active_cfg then updates.createUpdateOffer(active_cfg, node_id) end
    end

    function api.startOfferedUpdates()
        local active_cfg = getActiveConfig()
        if active_cfg then updates.startUpdateOffer(active_cfg) end
    end

    function api.abortUpdates()
        local active_cfg = getActiveConfig()
        if active_cfg then updates.abortUpdateFlow(active_cfg) end
    end

    function api.adoptReplacement(node_id)
        local active_cfg = getActiveConfig()
        if active_cfg then updates.adoptReplacement(active_cfg, node_id) end
    end

    return api
end

return actions