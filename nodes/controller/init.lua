-- nodes/controller/init.lua
-- Central authority node.
-- - Receives MATRIX/METER/REACTOR/GENERATOR telemetry from sensor nodes
-- - Evaluates auto-control thresholds and sends CMD_REACTOR_SET / CMD_GENERATOR_SET
-- - Broadcasts DISPLAY_UPDATE to display nodes
-- - Responds to POCKET_REQUEST / POCKET_CMD
-- - Drives the controller HUD via ui/controller_hud.lua
-- - Fires speaker / redstone / webhook alerts when conditions are met

local net  = require("lib/network")
local controller_link = require("lib/controller_link")
local actions = require("nodes/controller/actions")
local controller_view = require("lib/controller_view")
local handlers = require("nodes/controller/handlers")
local history = require("lib/history")
local history_policy = require("lib/history_policy")
local runtime = require("nodes/controller/runtime")
local telemetry = require("nodes/controller/telemetry")
local updates = require("nodes/controller/updates")
local pmgr = require("lib/peripheral_mgr")
local version = require("lib/version")
local runtime_actions = require("lib/runtime_actions")
local hud  = require("ui/controller_hud")
local runtime_panel = require("ui/runtime_panel")

local MODEM_TYPE     = "ender_modem"
local DISPLAY_INTERVAL = 1
local STALE_TIMEOUT    = 10
local UPDATE_TIMEOUT   = 180
local CHECK_TIMEOUT    = 6
local AUTO_CHECK_INTERVAL_DEFAULT = 90
local HISTORY_SAMPLE_INTERVAL = 1

local controller = {}
local runtime_ui = nil
local active_cfg = nil
local BRANCH = version.getBranchLabel()
local actions_ops
local refreshPanel
local handlers_ops
local runtime_ops
local telemetry_ops
local updates_ops

local state = {
    matrix  = nil,
    matrices = {},
    matrix_updated = 0,
    reactors = {},
    generators = {},
    meters = {},
    alerts   = {},
    alert_index = 1,
    last_webhook_fingerprint = "",
    last_webhook_at = 0,
    history = history.new({
        max_samples = 240,
        max_logs = 256,
        flush_every = 30,
        persist = false,
        persist_dir_name = "enmon-history",
        persist_id = "controller",
    }),
    last_history_sample = 0,
    updates  = {
        controller_version = version.getVersion(),
        latest_version = nil,
        rollout_policy = version.getRolloutPolicy(),
        nodes = {},
        last_check_ids = {},
        check_deadline = nil,
        offer = nil,
        last_abort_ids = {},
        rollout = nil,
    },
}

local function now()
    return os.clock()
end

local function logLine(msg, fg)
    if runtime_ui then
        runtime_ui.log(msg, fg)
    else
        print(msg)
    end
end

local function isStale(timestamp)
    return (now() - timestamp) > STALE_TIMEOUT
end

local function compareVersion(candidate, current)
    return version.compare(candidate or "0", current or "0")
end

local function getAutoCheckInterval(cfg)
    local value = tonumber(cfg.get("update_check_interval")) or AUTO_CHECK_INTERVAL_DEFAULT
    return math.max(15, math.floor(value + 0.5))
end

local function rememberNode(node_id, role, sender_id, payload)
    if not node_id then return nil end
    local entry = state.updates.nodes[node_id]
    local previous_sender = entry and entry.sender_id or nil
    local previous_role = entry and entry.role or nil
    local previous_seen = entry and entry.last_seen or nil
    local was_fresh = previous_seen and not isStale(previous_seen) or false

    if not entry then
        entry = { node_id = node_id }
        state.updates.nodes[node_id] = entry
    end

    local change = {
        is_new = previous_sender == nil and previous_role == nil,
        sender_changed = previous_sender ~= nil and sender_id ~= nil and previous_sender ~= sender_id,
        role_changed = previous_role ~= nil and role ~= nil and previous_role ~= role,
        was_fresh = was_fresh,
        controller_changed = false,
    }

    if role then entry.role = role end
    -- Discovery must not overwrite the routing identity of an already-linked node.
    local has_token = controller_link.hasStoredToken(node_id)
    local stored_sender = controller_link.getStoredSenderId(node_id)
    if sender_id then
        if has_token and stored_sender ~= nil and stored_sender ~= sender_id then
            change.sender_changed = previous_sender ~= nil and previous_sender ~= sender_id
            entry.pending_sender_id = sender_id
        else
            entry.sender_id = sender_id
        end
    end
    if type(payload) == "table" then
        if payload.local_version then entry.local_version = payload.local_version end
        if payload.version then entry.local_version = payload.version end
        if payload.controller_id ~= nil then entry.controller_id = payload.controller_id end
        if payload.status ~= nil then entry.node_status = payload.status end
        -- Ignore claim_code from the wire (out-of-band only).
        if payload.adopted ~= nil then entry.adopted = payload.adopted == true end
    end

    if has_token then
        entry.unlinked = false
        entry.adopted = true
        entry.claim_code = nil
        if stored_sender ~= nil and entry.pending_sender_id and stored_sender ~= entry.pending_sender_id then
            entry.identity_conflict = true
        end
    elseif entry.adopted == true then
        entry.unlinked = false
        entry.claim_code = nil
    elseif type(payload) == "table" and payload.status == "unlinked" then
        entry.unlinked = true
    end

    if change.sender_changed then
        entry.previous_sender_id = previous_sender
        entry.replaced_at = now()
        entry.identity_conflict = was_fresh
    end
    if change.role_changed then
        entry.previous_role = previous_role
        entry.role_changed_at = now()
        entry.identity_conflict = was_fresh or entry.identity_conflict == true
    end

    entry.last_seen = now()

    if entry.local_version and state.updates.latest_version then
        entry.needs_update = version.isNewer(state.updates.latest_version, entry.local_version)
    end
    local previous_controller = entry.controller_mismatch
    entry.controller_mismatch = entry.controller_id ~= nil and entry.controller_id ~= os.getComputerID()
    change.controller_changed = previous_controller ~= entry.controller_mismatch

    return entry, change
end

local function buildNodePayload(node_id, payload)
    return controller_link.buildControllerPayload(node_id, payload)
end

local function sendToNode(node_id, sender_id, msgType, payload, msg_id)
    return net.sendTargeted(msgType, buildNodePayload(node_id, payload), node_id, sender_id, nil, {
        msg_id = msg_id,
        auth_key = msgType ~= net.MSG.ADOPT_REQUEST and controller_link.getStoredToken(node_id) or nil,
    })
end

local function sendToEntry(entry, msgType, payload, msg_id)
    if not entry or not entry.node_id or not entry.sender_id then
        return false, "missing node routing"
    end
    return sendToNode(entry.node_id, entry.sender_id, msgType, payload, msg_id)
end

local function reportNodeChange(entry, change)
    if not entry or not change then return end
    if change.is_new then
        logLine("[ctrl] Node discovered: " .. tostring(entry.node_id) .. " (" .. tostring(entry.role or "unknown") .. ")", colors.lime)
    end
    if change.sender_changed then
        local label = change.was_fresh and "Duplicate/replaced node ID" or "Node replacement detected"
        local fg = change.was_fresh and colors.red or colors.orange
        logLine("[ctrl] " .. label .. ": " .. tostring(entry.node_id) .. " sender " .. tostring(entry.previous_sender_id) .. " -> " .. tostring(entry.sender_id), fg)
    end
    if change.role_changed then
        logLine("[ctrl] Node role changed: " .. tostring(entry.node_id) .. " " .. tostring(entry.previous_role) .. " -> " .. tostring(entry.role), colors.orange)
    end
    if entry.controller_mismatch and (change.is_new or change.sender_changed or change.role_changed or change.controller_changed) then
        logLine("[ctrl] Node uses different controller ID: " .. tostring(entry.node_id) .. " -> " .. tostring(entry.controller_id), colors.orange)
    end
end

local function refreshSelfEntry(cfg, status)
    local entry = rememberNode(cfg.get("node_id"), "controller", os.getComputerID(), {
        local_version = state.updates.controller_version,
        status = status or "online",
        controller_id = os.getComputerID(),
    })
    if entry then
        entry.local_version = state.updates.controller_version
        entry.needs_update = state.updates.latest_version and version.isNewer(state.updates.latest_version, entry.local_version) or false
        if not entry.needs_update then
            entry.update_status = "online-current"
        end
    end
    return entry
end

updates_ops = updates.new({
    state = state,
    now = now,
    isStale = isStale,
    logLine = logLine,
    refreshPanel = function(cfg)
        if refreshPanel then refreshPanel(cfg) end
    end,
    sendToNode = sendToNode,
    sendToEntry = sendToEntry,
    rememberNode = rememberNode,
    refreshSelfEntry = refreshSelfEntry,
    compareVersion = compareVersion,
    reportNodeChange = reportNodeChange,
    check_timeout = CHECK_TIMEOUT,
    update_timeout = UPDATE_TIMEOUT,
})

telemetry_ops = telemetry.new({
    state = state,
    isStale = isStale,
    buildUpdateSnapshot = function()
        return updates_ops.buildUpdateSnapshot()
    end,
    sendToNode = sendToNode,
    logLine = logLine,
    getEnergyUnit = function()
        return active_cfg and active_cfg.get("energy_unit") or "FE"
    end,
    now = now,
    sample_interval = HISTORY_SAMPLE_INTERVAL,
})

handlers_ops = handlers.new({
    state = state,
    now = now,
    logLine = logLine,
    rememberNode = rememberNode,
    reportNodeChange = reportNodeChange,
    refreshPanel = function(cfg)
        if refreshPanel then refreshPanel(cfg) end
    end,
    updates = updates_ops,
    telemetry = telemetry_ops,
    sendToNode = sendToNode,
    getActions = function()
        return actions_ops
    end,
})

refreshPanel = function(cfg)
    if not runtime_ui then return end
    runtime_ui.setSummary(controller_view.buildRuntimeSummaryRows(cfg, BRANCH, state, isStale, telemetry_ops.currentAlertText, updates_ops.buildRuntimeUpdatesLine))
end

runtime_ops = runtime.new({
    controller = controller,
    state = state,
    logLine = logLine,
    setRuntimeUi = function(ui)
        runtime_ui = ui
    end,
    refreshPanel = function(cfg)
        refreshPanel(cfg)
    end,
    refreshSelfEntry = refreshSelfEntry,
    telemetry = telemetry_ops,
    updates = updates_ops,
    handlers = handlers_ops,
    sendToEntry = sendToEntry,
    isStale = isStale,
    getAutoCheckInterval = getAutoCheckInterval,
    display_interval = DISPLAY_INTERVAL,
    modem_type = MODEM_TYPE,
    pmgr = pmgr,
    controller_link = controller_link,
    history = history,
    history_policy = history_policy,
    runtime_panel = runtime_panel,
    runtime_actions = runtime_actions,
    hud = hud,
    net = net,
})

actions_ops = actions.new({
    state = state,
    sendToEntry = sendToEntry,
    logLine = logLine,
    updates = updates_ops,
    getActiveConfig = function()
        return active_cfg
    end,
})

controller.setReactorActive = actions_ops.setReactorActive
controller.setReactorControlRodLevel = actions_ops.setReactorControlRodLevel
controller.adjustReactorControlRod = actions_ops.adjustReactorControlRod
controller.setGeneratorActive = actions_ops.setGeneratorActive
controller.requestUpdateCheck = actions_ops.requestUpdateCheck
controller.offerUpdates = actions_ops.offerUpdates
controller.startOfferedUpdates = actions_ops.startOfferedUpdates
controller.abortUpdates = actions_ops.abortUpdates
controller.adoptReplacement = actions_ops.adoptReplacement

function controller.run(cfg)
    active_cfg = cfg
    runtime_ops.run(cfg)
end

return controller
