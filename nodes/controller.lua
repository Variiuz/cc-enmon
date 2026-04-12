-- nodes/controller.lua
-- Central authority node.
-- - Receives MATRIX_DATA and REACTOR_DATA from sensor nodes
-- - Evaluates auto-control thresholds and sends CMD_REACTOR_SET
-- - Broadcasts DISPLAY_UPDATE to display nodes
-- - Responds to POCKET_REQUEST with POCKET_DATA
-- - Drives the controller HUD via ui/controller_hud.lua
-- - Fires speaker alerts when conditions are met

local net  = require("lib/network")
local pmgr = require("lib/peripheral_mgr")
local updater = require("lib/updater")
local util = require("lib/util")
local version = require("lib/version")
local runtime_actions = require("lib/runtime_actions")
local hud  = require("ui/controller_hud")
local runtime_panel = require("ui/runtime_panel")

local MODEM_TYPE     = "ender_modem"
local DISPLAY_INTERVAL = 1  -- seconds between DISPLAY_UPDATE broadcasts
local STALE_TIMEOUT    = 10 -- seconds before a node is marked disconnected
local UPDATE_TIMEOUT   = 180
local CHECK_TIMEOUT    = 6
local AUTO_CHECK_INTERVAL_DEFAULT = 90

local UPDATE_ORDER = {
    display = 1,
    pocket = 2,
    matrix = 3,
    reactor = 4,
    controller = 5,
}

local controller = {}
local runtime_ui = nil
local active_cfg = nil
local rolloutRank
local performUpdateCheck

-- ── State ───────────────────────────────────────────────────────────────────────
-- matrix_state: latest data from any matrix node
-- reactors: table keyed by node_id, each entry holds latest reactor data + timestamps
-- alerts: table of active alert strings
local state = {
    matrix  = nil,
    matrix_updated = 0,
    reactors = {},
    alerts   = {},
    alert_index = 1,
    updates  = {
        controller_version = version.getVersion(),
        latest_version = nil,
        rollout_policy = version.getRolloutPolicy(),
        nodes = {},
        last_check_id = nil,
        check_deadline = nil,
        offer = nil,
        last_abort_ids = {},
        rollout = nil,
    },
}

-- ── Helpers ─────────────────────────────────────────────────────────────────────
local function now() return os.clock() end

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
    if sender_id then entry.sender_id = sender_id end
    if type(payload) == "table" then
        if payload.local_version then entry.local_version = payload.local_version end
        if payload.version then entry.local_version = payload.version end
        if payload.controller_id ~= nil then entry.controller_id = payload.controller_id end
        if payload.status ~= nil then entry.node_status = payload.status end
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

local function sortQueue(queue)
    table.sort(queue, function(left, right)
        local lr = rolloutRank(left)
        local rr = rolloutRank(right)
        if lr == rr then
            return tostring(left.node_id) < tostring(right.node_id)
        end
        return lr < rr
    end)
end

local function queueNodeForRollout(entry, reason)
    local rollout = state.updates.rollout
    if not rollout or not entry or not entry.node_id then return false end
    if rollout.cancelled then return false end
    if entry.role == "controller" or entry.sender_id == nil then return false end

    if entry.controller_mismatch then
        entry.update_status = "wrong-controller"
        rollout.pending[entry.node_id] = "wrong-controller"
        return false
    end
    if entry.identity_conflict then
        entry.update_status = "identity-conflict"
        rollout.pending[entry.node_id] = "identity-conflict"
        return false
    end

    local desired = rollout.latest_version
    local needs = entry.local_version and version.isNewer(desired, entry.local_version) or entry.needs_update == true
    if not needs then
        entry.needs_update = false
        return false
    end

    if isStale(entry.last_seen or 0) then
        entry.update_status = "pending-offline"
        rollout.pending[entry.node_id] = reason or "offline"
        return false
    end

    if rollout.current and rollout.current.node_id == entry.node_id then
        return false
    end
    if rollout.queued[entry.node_id] then
        return false
    end

    rollout.queue[#rollout.queue + 1] = {
        node_id = entry.node_id,
        sender_id = entry.sender_id,
        role = entry.role,
    }
    rollout.queued[entry.node_id] = true
    rollout.pending[entry.node_id] = nil
    entry.update_status = "queued"
    sortQueue(rollout.queue)
    return true
end

local function reconcileNode(entry, cfg, source)
    if not entry then return end

    if entry.local_version and state.updates.latest_version then
        entry.needs_update = version.isNewer(state.updates.latest_version, entry.local_version)
        if not entry.needs_update and (entry.update_status == "starting" or entry.update_status == "ack" or entry.update_status == "in_progress" or entry.update_status == "timeout" or entry.update_status == "pending-offline") then
            entry.update_status = "online-current"
            entry.update_phase = source or "reconciled"
        end
    end

    local rollout = state.updates.rollout
    if not rollout then return end

    if entry.node_id and rollout.pending[entry.node_id] and not entry.needs_update then
        rollout.pending[entry.node_id] = nil
    end

    if rollout.current and rollout.current.node_id == entry.node_id and not entry.needs_update then
        logLine("[ctrl] Node returned on target version: " .. tostring(entry.node_id), colors.lime)
        rollout.current = nil
    elseif entry.needs_update then
        queueNodeForRollout(entry, source or "rejoin")
    end
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

local function effectiveNodeStatus(entry)
    if not entry then return "unknown" end
    if entry.controller_mismatch then return "wrong-controller" end
    if entry.identity_conflict then return "identity-conflict" end
    if isStale(entry.last_seen or 0) then
        if entry.update_status == "pending-offline" then return "pending-offline" end
        return "offline"
    end
    if entry.update_status and entry.update_status ~= "" then
        return entry.update_status
    end
    if entry.node_status == "version-mismatch" then return "version-mismatch" end
    if entry.needs_update == false then return "online-current" end
    return "online"
end

local function buildVersionPath(local_version, latest_version, needs_update)
    local current = local_version or "--"
    local target = latest_version

    if not target or target == "" or target == "--" then
        return current
    end

    if needs_update == true then
        return tostring(current) .. "->" .. tostring(target)
    end

    return current
end

local function controllerEntry(cfg)
    return state.updates.nodes[cfg.get("node_id")]
end

local function rolloutPolicy()
    return state.updates.rollout_policy or version.getRolloutPolicy() or "controller-first"
end

local function nodeVersionCompatible(entry)
    if not entry or entry.role == "controller" then
        return true
    end
    if rolloutPolicy() == "node-safe" then
        return true
    end
    if not entry.local_version or not state.updates.controller_version then
        return false
    end
    return compareVersion(entry.local_version, state.updates.controller_version) == 0
end

local function blockMismatchedOperationalNode(entry, kind)
    if not entry or nodeVersionCompatible(entry) then
        return false
    end

    local blocked_note = "Blocked until updated to controller version " .. tostring(state.updates.controller_version)
    local changed = entry.message ~= blocked_note or entry.node_status ~= "version-mismatch"
    entry.node_status = "version-mismatch"
    entry.message = blocked_note
    if changed then
        logLine("[ctrl] Blocking " .. tostring(kind or entry.role or "node") .. " from version-mismatched node " .. tostring(entry.node_id) .. " (" .. tostring(entry.local_version or "unknown") .. " != " .. tostring(state.updates.controller_version) .. ")", colors.orange)
    end
    return true
end

local function controllerNeedsReviewUpdate(cfg)
    local entry = controllerEntry(cfg)
    if entry and entry.needs_update == true then
        return true, entry
    end
    return false, entry
end

local function ensureControllerCurrentForRemoteUpdates(cfg)
    if rolloutPolicy() ~= "controller-first" then
        return true
    end

    if not state.updates.latest_version then
        local ok = performUpdateCheck(cfg, false)
        if not ok then
            return false
        end
    end

    local needsUpdate = controllerNeedsReviewUpdate(cfg)
    if needsUpdate then
        logLine("[ctrl] Controller update must be reviewed/applied before remote node updates", colors.orange)
        refreshPanel(cfg)
        return false
    end

    return true
end

local function selectRuntimeUpdateEntry(cfg)
    local rollout = state.updates.rollout
    if rollout and rollout.current then
        return state.updates.nodes[rollout.current.node_id]
    end

    local candidates = {}
    for node_id, entry in pairs(state.updates.nodes) do
        if node_id ~= cfg.get("node_id") and entry.role ~= "controller" and entry.needs_update == true then
            candidates[#candidates + 1] = entry
        end
    end

    sortQueue(candidates)
    return candidates[1]
end

local function buildRuntimeUpdateSummary(cfg)
    local entry = selectRuntimeUpdateEntry(cfg)
    if entry then
        return tostring(entry.node_id), buildVersionPath(entry.local_version or "--", state.updates.latest_version, entry.needs_update == true) .. "  " .. tostring(effectiveNodeStatus(entry))
    end

    if state.updates.latest_version then
        return "All", "Current @ " .. tostring(state.updates.latest_version)
    end

    return "--", "--"
end

local function buildUpdateSnapshot()
    local updates = state.updates
    local counts = {
        queued = 0,
        pending_offline = 0,
        identity_conflict = 0,
        wrong_controller = 0,
        offered = 0,
    }
    local nodes = {}

    for node_id, entry in pairs(updates.nodes) do
        local status = effectiveNodeStatus(entry)
        if status == "queued" then counts.queued = counts.queued + 1 end
        if status == "pending-offline" then counts.pending_offline = counts.pending_offline + 1 end
        if status == "identity-conflict" then counts.identity_conflict = counts.identity_conflict + 1 end
        if status == "wrong-controller" then counts.wrong_controller = counts.wrong_controller + 1 end
        if status == "offered" then counts.offered = counts.offered + 1 end

        nodes[#nodes + 1] = {
            node_id = node_id,
            role = entry.role or "unknown",
            sender_id = entry.sender_id,
            local_version = entry.local_version or "--",
            version_display = buildVersionPath(entry.local_version or "--", updates.latest_version, entry.needs_update == true),
            target_version = updates.latest_version,
            status = status,
            needs_update = entry.needs_update == true,
            stale = isStale(entry.last_seen or 0),
            note = entry.message or entry.node_status or (entry.role == "controller" and "Review controller update here, then apply locally with F9 on the controller terminal" or nil),
        }
    end

    table.sort(nodes, function(left, right)
        local lr = rolloutRank(left)
        local rr = rolloutRank(right)
        if lr == rr then
            return tostring(left.node_id) < tostring(right.node_id)
        end
        return lr < rr
    end)

    local phase = "idle"
    if updates.offer then
        phase = "offer"
    elseif updates.rollout then
        phase = updates.rollout.cancelled and "aborting" or "rollout"
    end

    return {
        controller_version = updates.controller_version,
        latest_version = updates.latest_version,
        rollout_policy = updates.rollout_policy,
        phase = phase,
        offer = updates.offer and {
            latest_version = updates.offer.latest_version,
            target_count = #updates.offer.queue,
            pending_count = updates.offer.pending_count or 0,
        } or nil,
        rollout = updates.rollout and {
            current = updates.rollout.current and updates.rollout.current.node_id or nil,
            queued = #updates.rollout.queue,
            cancelled = updates.rollout.cancelled == true,
        } or nil,
        counts = counts,
        nodes = nodes,
    }
end

local function collectOfferTargets(cfg, target_node_id)
    local queue = {}
    local pending = {}
    local foundTarget = target_node_id == nil

    for node_id, entry in pairs(state.updates.nodes) do
        if node_id ~= cfg.get("node_id") and entry.role ~= "controller" and entry.sender_id then
            if target_node_id == nil or node_id == target_node_id then
                foundTarget = true
                if entry.controller_mismatch then
                    entry.update_status = "wrong-controller"
                elseif entry.identity_conflict then
                    entry.update_status = "identity-conflict"
                else
                    local needsUpdate = entry.needs_update
                    if needsUpdate == nil and entry.local_version and state.updates.latest_version then
                        needsUpdate = version.isNewer(state.updates.latest_version, entry.local_version)
                    end
                    if needsUpdate then
                        if isStale(entry.last_seen or 0) then
                            entry.update_status = "pending-offline"
                            pending[node_id] = "offline"
                        else
                            queue[#queue + 1] = {
                                node_id = node_id,
                                sender_id = entry.sender_id,
                                role = entry.role,
                            }
                            entry.update_status = "queued"
                        end
                    end
                end
            end
        end
    end

    sortQueue(queue)
    return foundTarget, queue, pending
end

rolloutRank = function(entry)
    return UPDATE_ORDER[entry.role] or 99
end

local function updateAlerts(cfg)
    local new_alerts = {}

    -- Matrix stale / disconnected
    if state.matrix == nil or isStale(state.matrix_updated) then
        new_alerts[#new_alerts+1] = "MATRIX: No data"
    else
        local fill = util.fillFraction(state.matrix.energy, state.matrix.max_energy)
        if fill <= cfg.get("threshold_low") then
            new_alerts[#new_alerts+1] = "ENERGY LOW: " .. util.formatPercent(fill)
        elseif fill >= cfg.get("threshold_high") then
            new_alerts[#new_alerts+1] = "ENERGY HIGH: " .. util.formatPercent(fill)
        end
    end

    -- Reactor disconnected
    for nid, r in pairs(state.reactors) do
        if isStale(r.updated) then
            new_alerts[#new_alerts+1] = "REACTOR " .. nid .. ": No data"
        end
    end

    state.alerts = new_alerts
    if #state.alerts == 0 then
        state.alert_index = 1
    else
        state.alert_index = math.max(1, math.min(state.alert_index or 1, #state.alerts))
    end
end

local function currentAlertText()
    if #state.alerts == 0 then
        return "All nominal", colors.black, colors.white
    end

    local index = state.alert_index or 1
    if index < 1 or index > #state.alerts then
        index = 1
        state.alert_index = 1
    end
    return state.alerts[index], colors.red, colors.white
end

local function rotateAlert()
    if #state.alerts <= 1 then return end
    state.alert_index = (state.alert_index % #state.alerts) + 1
end

local function playAlerts(speaker, cfg)
    if not speaker then return end
    if #state.alerts > 0 then
        pcall(speaker.playNote, speaker, "harp", 1, 6)
    end
end

-- Auto-control: send CMD_REACTOR_SET to all known reactor nodes.
local function autoControl(cfg)
    if not cfg.get("auto_ctrl") then return end
    if state.matrix == nil or isStale(state.matrix_updated) then return end

    local fill = util.fillFraction(state.matrix.energy, state.matrix.max_energy)
    local lo   = cfg.get("threshold_low")
    local hi   = cfg.get("threshold_high")

    local want_active = nil
    if fill <= lo then
        want_active = true
    elseif fill >= hi then
        want_active = false
    end

    if want_active == nil then return end

    for nid, r in pairs(state.reactors) do
        if not isStale(r.updated) and r.active ~= want_active then
            net.send(net.MSG.CMD_REACTOR_SET, { active = want_active })
            r.pending_active = want_active
            logLine("[ctrl] auto-ctrl: reactor " .. nid ..
                  " -> " .. tostring(want_active) ..
                  " (fill " .. util.formatPercent(fill) .. ")", colors.lightBlue)
        end
    end
end

-- Build DISPLAY_UPDATE payload from current state.
local function buildDisplayPayload()
    return {
        matrix   = state.matrix,
        matrix_stale = (state.matrix == nil or isStale(state.matrix_updated)),
        reactors = state.reactors,
        alerts   = state.alerts,
        updates  = buildUpdateSnapshot(),
        timestamp = util.timestamp(),
    }
end

local function refreshPanel(cfg)
    if not runtime_ui then return end

    local reactor_count = 0
    for _ in pairs(state.reactors) do reactor_count = reactor_count + 1 end

    local matrix_status = "Waiting"
    local matrix_fg = colors.black
    local matrix_bg = colors.white
    if state.matrix and not isStale(state.matrix_updated) then
        matrix_status = util.formatPercent(util.fillFraction(state.matrix.energy, state.matrix.max_energy))
        matrix_fg = colors.white
        matrix_bg = colors.blue
    elseif state.matrix and isStale(state.matrix_updated) then
        matrix_status = "Stale"
        matrix_fg = colors.red
        matrix_bg = colors.white
    end

    local alert_text, alert_fg, alert_bg = currentAlertText()
    local update_node, update_path = buildRuntimeUpdateSummary(cfg)

    runtime_ui.setSummary({
        { "Computer ID", tostring(os.getComputerID()), colors.white, colors.blue },
        { "Node", tostring(cfg.get("node_id")) },
        { "Version", tostring(state.updates.controller_version) .. (state.updates.latest_version and (" -> " .. tostring(state.updates.latest_version)) or "") },
        { "Update Node", update_node },
        { "Update Path", update_path },
        { "Channel", tostring(cfg.get("channel")) },
        { "Matrix", matrix_status, matrix_fg, matrix_bg },
        { "Reactors", tostring(reactor_count) },
        { "Alert", alert_text, alert_fg, alert_bg },
    })
end

-- ── Message handlers ─────────────────────────────────────────────────────────────
local function onMatrixData(msg, cfg)
    local entry, change = rememberNode(msg.node_id, "matrix", msg.sender_id, msg.payload)
    reportNodeChange(entry, change)
    reconcileNode(entry, cfg, "matrix-data")
    if blockMismatchedOperationalNode(entry, "matrix data") then
        refreshPanel(cfg)
        return
    end
    state.matrix         = msg.payload
    state.matrix_updated = now()
    updateAlerts(cfg)
    autoControl(cfg)
end

local function onReactorData(msg, cfg)
    local nid = msg.node_id
    local entry, change = rememberNode(nid, "reactor", msg.sender_id, msg.payload)
    reportNodeChange(entry, change)
    reconcileNode(entry, cfg, "reactor-data")
    if blockMismatchedOperationalNode(entry, "reactor data") then
        refreshPanel(cfg)
        return
    end
    if not state.reactors[nid] then
        state.reactors[nid] = {}
        logLine("[ctrl] New reactor node registered: " .. nid, colors.lime)
    end
    local r = state.reactors[nid]
    r.active          = msg.payload.active
    r.produced_last_t = msg.payload.produced_last_t
    r.updated         = now()
    r.node_id         = nid
    r.sender_id       = msg.sender_id
    updateAlerts(cfg)
    refreshPanel(cfg)
end

local function onPocketRequest(msg, cfg)
    local entry, change = rememberNode(msg.node_id, "pocket", msg.sender_id, msg.payload)
    reportNodeChange(entry, change)
    reconcileNode(entry, cfg, "pocket-request")
    if blockMismatchedOperationalNode(entry, "pocket request") then
        refreshPanel(cfg)
        return
    end
    local payload = buildDisplayPayload()
    -- Reply directly to the requesting computer's ID via targeted send
    -- (ender modems broadcast on a channel; we include source computer ID so
    --  the pocket node can filter its own responses)
    payload.for_sender = msg.sender_id
    net.send(net.MSG.POCKET_DATA, payload)
end

local function onNodeHello(msg, cfg)
    local payload = msg.payload or {}
    local entry, change = rememberNode(msg.node_id, payload.role, msg.sender_id, payload)
    reportNodeChange(entry, change)
    reconcileNode(entry, cfg, payload.status or "hello")
    blockMismatchedOperationalNode(entry, "node hello")
    refreshPanel(cfg)
end

local function onUpdateAck(msg, cfg)
    if not net.isTargetedToSelf(msg) then return end
    local rollout = state.updates.rollout
    if not rollout or not rollout.current or msg.msg_id ~= rollout.current.msg_id then
        return
    end

    local entry, change = rememberNode(msg.node_id, (msg.payload and msg.payload.role) or nil, msg.sender_id, msg.payload)
    reportNodeChange(entry, change)
    if entry then
        entry.update_status = "ack"
    end
    logLine("[ctrl] Update ACK from " .. tostring(msg.node_id), colors.lightBlue)
    refreshPanel(cfg)
end

local function onUpdateStatus(msg, cfg)
    if not net.isTargetedToSelf(msg) then return end
    local payload = msg.payload or {}
    if payload.phase == "check" and msg.msg_id ~= state.updates.last_check_id then
        return
    end

    local offer = state.updates.offer
    if payload.phase == "offer" then
        if not offer or offer.msg_ids[msg.node_id] ~= msg.msg_id then
            return
        end
    elseif payload.phase == "abort" then
        if state.updates.last_abort_ids[msg.node_id] ~= msg.msg_id then
            return
        end
    end

    local rollout = state.updates.rollout
    if payload.phase ~= "check" and payload.phase ~= "offer" and payload.phase ~= "abort" then
        if not rollout or not rollout.current or msg.node_id ~= rollout.current.node_id or msg.msg_id ~= rollout.current.msg_id then
            return
        end
    end
    if payload.phase ~= "check" and payload.phase ~= "offer" and payload.phase ~= "abort" and rollout and rollout.current and msg.node_id == rollout.current.node_id and msg.msg_id ~= rollout.current.msg_id then
        return
    end

    local entry, change = rememberNode(msg.node_id, payload.role, msg.sender_id, payload)
    reportNodeChange(entry, change)
    if entry then
        entry.needs_update = payload.needs_update
        entry.update_status = payload.status or entry.update_status
        entry.update_phase = payload.phase or entry.update_phase
        entry.message = payload.message or entry.message
    end

    local summary = "[ctrl] Update status from " .. tostring(msg.node_id) .. ": " .. tostring(payload.status or "unknown")
    if payload.phase then
        summary = summary .. " (" .. tostring(payload.phase) .. ")"
    end
    if payload.message then
        summary = summary .. " - " .. tostring(payload.message)
    end
    logLine(summary, payload.status == "failed" and colors.red or colors.lightBlue)

    if payload.phase == "check" then
        reconcileNode(entry, cfg, "check")
    elseif payload.phase == "offer" then
        if entry then entry.update_status = payload.status or "offered" end
    elseif payload.phase == "abort" then
        if entry then entry.update_status = payload.status or "aborted" end
    elseif rollout and rollout.current and rollout.current.node_id == msg.node_id then
        if payload.status == "success" or payload.status == "failed" or payload.status == "noop" then
            rollout.current = nil
        elseif payload.status == "in_progress" then
            rollout.current.deadline = now() + UPDATE_TIMEOUT
        end
    end

    reconcileNode(entry, cfg, payload.phase or "status")
    refreshPanel(cfg)
end

local function createUpdateOffer(cfg, target_node_id)
    if state.updates.rollout then
        logLine("[ctrl] Cannot create a new offer while rollout is active", colors.orange)
        return false
    end
    if target_node_id and target_node_id == cfg.get("node_id") then
        logLine("[ctrl] Controller updates are local-only via enmon-cli update", colors.orange)
        return false
    end
    if not ensureControllerCurrentForRemoteUpdates(cfg) then
        return false
    end

    local foundTarget, queue, pending = collectOfferTargets(cfg, target_node_id)
    if not foundTarget then
        logLine("[ctrl] Selected node not found", colors.orange)
        return false
    end
    if #queue == 0 and next(pending) == nil then
        logLine("[ctrl] No eligible nodes to offer an update", colors.orange)
        return false
    end

    local offer = {
        latest_version = state.updates.latest_version,
        queue = queue,
        pending = pending,
        pending_count = 0,
        msg_ids = {},
        scope = target_node_id,
    }

    for node_id in pairs(pending) do
        offer.pending_count = offer.pending_count + 1
        local entry = state.updates.nodes[node_id]
        if entry then entry.update_status = "pending-offline" end
    end

    for _, item in ipairs(queue) do
        local _, _, msg_id = net.sendTargeted(net.MSG.UPDATE_OFFER, {
            desired_version = offer.latest_version,
            force = false,
        }, item.node_id, item.sender_id)
        offer.msg_ids[item.node_id] = msg_id
        local entry = state.updates.nodes[item.node_id]
        if entry then entry.update_status = "offered" end
    end

    state.updates.offer = offer
    logLine("[ctrl] Update offer prepared for " .. tostring(#queue) .. " node(s)", colors.lime)
    refreshPanel(cfg)
    return true
end

local function startUpdateOffer(cfg)
    local offer = state.updates.offer
    if not offer then
        logLine("[ctrl] No pending update offer", colors.orange)
        return false
    end

    if not ensureControllerCurrentForRemoteUpdates(cfg) then
        state.updates.offer = nil
        refreshPanel(cfg)
        return false
    end

    state.updates.rollout = {
        queue = offer.queue,
        queued = {},
        pending = offer.pending,
        latest_version = offer.latest_version,
        current = nil,
        waiting_logged = false,
        cancelled = false,
    }
    for _, item in ipairs(offer.queue) do
        state.updates.rollout.queued[item.node_id] = true
    end
    state.updates.offer = nil
    logLine("[ctrl] Starting offered rollout", colors.lime)
    refreshPanel(cfg)
    return true
end

local function abortUpdateFlow(cfg)
    local aborted_any = false
    state.updates.last_abort_ids = {}

    if state.updates.offer then
        for _, item in ipairs(state.updates.offer.queue) do
            local _, _, msg_id = net.sendTargeted(net.MSG.UPDATE_ABORT, {
                reason = "operator-cancelled",
            }, item.node_id, item.sender_id)
            state.updates.last_abort_ids[item.node_id] = msg_id
            local entry = state.updates.nodes[item.node_id]
            if entry then entry.update_status = "aborted" end
            aborted_any = true
        end
        for node_id in pairs(state.updates.offer.pending) do
            local entry = state.updates.nodes[node_id]
            if entry and entry.update_status == "pending-offline" then
                entry.update_status = "aborted"
            end
        end
        state.updates.offer = nil
    end

    local rollout = state.updates.rollout
    if rollout then
        rollout.cancelled = true
        for _, item in ipairs(rollout.queue) do
            local _, _, msg_id = net.sendTargeted(net.MSG.UPDATE_ABORT, {
                reason = "operator-cancelled",
            }, item.node_id, item.sender_id)
            state.updates.last_abort_ids[item.node_id] = msg_id
            local entry = state.updates.nodes[item.node_id]
            if entry then entry.update_status = "aborted" end
            aborted_any = true
        end
        rollout.queue = {}
        rollout.queued = {}
        rollout.pending = {}

        if rollout.current then
            local current = state.updates.nodes[rollout.current.node_id]
            if current and current.sender_id then
                local _, _, msg_id = net.sendTargeted(net.MSG.UPDATE_ABORT, {
                    reason = "operator-cancelled",
                }, current.node_id, current.sender_id)
                state.updates.last_abort_ids[current.node_id] = msg_id
                current.update_status = "abort-requested"
                aborted_any = true
            end
        else
            state.updates.rollout = nil
        end
    end

    if aborted_any then
        logLine("[ctrl] Update flow cancelled", colors.orange)
        refreshPanel(cfg)
        return true
    end

    logLine("[ctrl] No active offer or rollout to cancel", colors.orange)
    return false
end

local function adoptReplacement(cfg, node_id)
    if not node_id or node_id == "" then
        logLine("[ctrl] Select a node to adopt", colors.orange)
        return false
    end

    local entry = state.updates.nodes[node_id]
    if not entry then
        logLine("[ctrl] Node not found: " .. tostring(node_id), colors.orange)
        return false
    end
    if not entry.identity_conflict then
        logLine("[ctrl] Node is not marked as conflicted", colors.orange)
        return false
    end

    entry.identity_conflict = false
    entry.previous_sender_id = nil
    entry.replaced_at = now()
    if entry.controller_mismatch then
        logLine("[ctrl] Replacement adopted, but controller ID still does not match", colors.orange)
    else
        logLine("[ctrl] Replacement adopted for " .. tostring(node_id), colors.lime)
    end
    reconcileNode(entry, cfg, "adopted")
    refreshPanel(cfg)
    return true
end

performUpdateCheck = function(cfg, force)
    local info, err = updater.checkForUpdate(cfg.get("role"), nil, false)
    if not info then
        logLine("[ctrl] Update check failed: " .. tostring(err), colors.red)
        return false
    end

    state.updates.controller_version = info.current_version
    state.updates.latest_version = info.latest_version
    state.updates.rollout_policy = info.rollout_policy or version.getRolloutPolicy()

    local selfEntry = refreshSelfEntry(cfg, "online")
    if selfEntry then
        selfEntry.local_version = info.current_version
        selfEntry.needs_update = info.needs_update
        selfEntry.update_status = info.needs_update and "ready" or "online-current"
    end

    logLine("[ctrl] Latest manifest version: " .. tostring(info.latest_version) .. " (local " .. tostring(info.current_version) .. ", policy " .. tostring(state.updates.rollout_policy or "controller-first") .. ")", colors.lightBlue)
    local _, _, msg_id = net.send(net.MSG.UPDATE_CHECK, { desired_version = info.latest_version, force = false })
    state.updates.last_check_id = msg_id
    state.updates.check_deadline = now() + CHECK_TIMEOUT
    for node_id, entry in pairs(state.updates.nodes) do
        if node_id ~= cfg.get("node_id") then
            entry.needs_update = nil
            if not isStale(entry.last_seen or 0) then
                entry.update_status = "checking"
            end
        end
    end
    refreshPanel(cfg)
    return true
end

local function startRollout(cfg)
    if state.updates.rollout then
        logLine("[ctrl] Update rollout already running", colors.orange)
        return
    end
    if not ensureControllerCurrentForRemoteUpdates(cfg) then
        return
    end

    local queue = {}
    for node_id, entry in pairs(state.updates.nodes) do
        if node_id ~= cfg.get("node_id") and entry.role ~= "controller" and entry.sender_id then
            if entry.controller_mismatch then
                entry.update_status = "wrong-controller"
            elseif entry.identity_conflict then
                entry.update_status = "identity-conflict"
            else
                local needsUpdate = entry.needs_update
                if needsUpdate == nil and entry.local_version and state.updates.latest_version then
                    needsUpdate = version.isNewer(state.updates.latest_version, entry.local_version)
                end
                if needsUpdate then
                    if isStale(entry.last_seen or 0) then
                        entry.update_status = "pending-offline"
                    else
                        queue[#queue + 1] = {
                            node_id = node_id,
                            sender_id = entry.sender_id,
                            role = entry.role,
                        }
                        entry.update_status = "queued"
                    end
                end
            end
        end
    end

    sortQueue(queue)

    if #queue == 0 then
        local pending = false
        local pending_map = {}
        for _, entry in pairs(state.updates.nodes) do
            if entry.update_status == "pending-offline" then
                pending = true
                pending_map[entry.node_id] = "offline"
            end
        end
        if pending then
            state.updates.rollout = {
                queue = {},
                queued = {},
                pending = pending_map,
                latest_version = state.updates.latest_version,
                current = nil,
                waiting_logged = false,
            }
            logLine("[ctrl] Waiting for unreachable nodes to return before rollout completes", colors.orange)
            return
        end
        logLine("[ctrl] No eligible remote nodes need updating", colors.orange)
        return
    end

    state.updates.rollout = {
        queue = queue,
        queued = {},
        pending = {},
        latest_version = state.updates.latest_version,
        current = nil,
        waiting_logged = false,
    }
    for _, item in ipairs(queue) do
        state.updates.rollout.queued[item.node_id] = true
    end
    for node_id, entry in pairs(state.updates.nodes) do
        if entry.update_status == "pending-offline" then
            state.updates.rollout.pending[node_id] = "offline"
        end
    end
    logLine("[ctrl] Queued " .. tostring(#queue) .. " node(s) for rollout to " .. tostring(state.updates.latest_version), colors.lime)
end

local function tickRollout(cfg)
    if state.updates.check_deadline and now() >= state.updates.check_deadline then
        state.updates.check_deadline = nil
        for node_id, entry in pairs(state.updates.nodes) do
            if node_id ~= cfg.get("node_id") and entry.update_status == "checking" then
                entry.update_status = isStale(entry.last_seen or 0) and "offline" or "no-check-response"
            end
        end
    end

    local rollout = state.updates.rollout
    if not rollout then return end

    if rollout.current then
        if now() >= rollout.current.deadline then
            logLine("[ctrl] Update timed out for " .. tostring(rollout.current.node_id), colors.red)
            local entry = state.updates.nodes[rollout.current.node_id]
            if entry then
                entry.update_status = "timeout"
                rollout.pending[rollout.current.node_id] = "timeout"
            end
            rollout.current = nil
        end
        return
    end

    local nextNode = table.remove(rollout.queue, 1)
    if not nextNode then
        local has_pending = false
        for _ in pairs(rollout.pending or {}) do
            has_pending = true
            break
        end
        if has_pending then
            if not rollout.waiting_logged then
                logLine("[ctrl] Waiting on pending nodes to return", colors.orange)
                rollout.waiting_logged = true
            end
            return
        end
        state.updates.rollout = nil
        logLine("[ctrl] Remote update rollout complete", colors.lime)
        refreshPanel(cfg)
        return
    end

    local live = state.updates.nodes[nextNode.node_id]
    if not live or not live.sender_id or isStale(live.last_seen or 0) then
        logLine("[ctrl] Skipping offline node: " .. tostring(nextNode.node_id), colors.orange)
        rollout.pending[nextNode.node_id] = "offline"
        rollout.queued[nextNode.node_id] = nil
        return
    end
    if live.controller_mismatch or live.identity_conflict then
        logLine("[ctrl] Skipping conflicted node: " .. tostring(nextNode.node_id), colors.orange)
        rollout.pending[nextNode.node_id] = live.controller_mismatch and "wrong-controller" or "identity-conflict"
        rollout.queued[nextNode.node_id] = nil
        return
    end

    logLine("[ctrl] Starting update on " .. tostring(nextNode.node_id) .. " (" .. tostring(nextNode.role) .. ")", colors.lightBlue)
    local _, _, msg_id = net.sendTargeted(net.MSG.UPDATE_START, {
        desired_version = rollout.latest_version,
        force = false,
    }, nextNode.node_id, nextNode.sender_id)

    live.update_status = "starting"
    rollout.queued[nextNode.node_id] = nil
    rollout.current = {
        node_id = nextNode.node_id,
        msg_id = msg_id,
        deadline = now() + UPDATE_TIMEOUT,
    }
    refreshPanel(cfg)
end

local function updateSelf(cfg)
    if state.updates.rollout then
        logLine("[ctrl] Finish remote rollout before self-update", colors.orange)
        return
    end

    if not state.updates.latest_version then
        local ok = performUpdateCheck(cfg, false)
        if not ok then
            return
        end
        local needsUpdate = controllerNeedsReviewUpdate(cfg)
        if needsUpdate then
            logLine("[ctrl] Review controller update in the Updates view, then press F9 again to apply", colors.lightBlue)
            refreshPanel(cfg)
            return
        end
    end

    local needsUpdate = controllerNeedsReviewUpdate(cfg)
    if not needsUpdate then
        logLine("[ctrl] Controller already on latest version", colors.lime)
        return
    end

    local ok, result = updater.applyLocalUpdate({
        role = cfg.get("role"),
        force = false,
        logger = function(message)
            logLine("[ctrl-update] " .. tostring(message), colors.lightBlue)
        end,
    })

    if not ok then
        logLine("[ctrl] Self-update failed: " .. tostring(result), colors.red)
        return
    end
    if not result.updated then
        logLine("[ctrl] Controller already on latest version", colors.lime)
        return
    end

    logLine("[ctrl] Controller updated to " .. tostring(result.to_version) .. "; rebooting", colors.lime)
    os.sleep(0.3)
    os.reboot()
end

-- ── Manual reactor toggle (called from HUD) ──────────────────────────────────────
function controller.setReactorActive(node_id, active)
    net.send(net.MSG.CMD_REACTOR_SET, { active = active })
    logLine("[ctrl] manual CMD_REACTOR_SET -> " .. tostring(active) ..
          " (node: " .. tostring(node_id) .. ")", colors.lightBlue)
end

function controller.requestUpdateCheck()
    if active_cfg then performUpdateCheck(active_cfg, false) end
end

function controller.offerUpdates(node_id)
    if active_cfg then createUpdateOffer(active_cfg, node_id) end
end

function controller.startOfferedUpdates()
    if active_cfg then startUpdateOffer(active_cfg) end
end

function controller.abortUpdates()
    if active_cfg then abortUpdateFlow(active_cfg) end
end

function controller.adoptReplacement(node_id)
    if active_cfg then adoptReplacement(active_cfg, node_id) end
end

-- ── Main run loop ────────────────────────────────────────────────────────────────
function controller.run(cfg)
    active_cfg = cfg
    runtime_ui = runtime_panel.new("Controller")
    runtime_ui.setHint("F2 Config | F4 View | F5 Check | F6 Offer | F7 Start | F8 Abort | F9 Self")
    logLine("[ctrl] Starting controller: " .. cfg.get("node_id"), colors.lime)

    -- Open network
    local modem = pmgr.find(MODEM_TYPE) or pmgr.find("modem")
    if not modem then error("No ender modem found.") end
    net.open(modem, cfg.get("channel"), cfg.get("shared_secret"), cfg.get("node_id"))

    -- Find speaker (optional)
    local speaker = nil
    local spk_side = cfg.get("speaker_side")
    if spk_side then
        speaker = pmgr.wrap(spk_side)
        if speaker then logLine("[ctrl] Speaker attached: " .. spk_side, colors.lime) end
    end
    refreshPanel(cfg)

    -- Initialise HUD (sets up Basalt on the monitor)
    local mon_side = cfg.get("monitor_side")
    hud.init(mon_side, cfg, controller)
    local selfEntry = refreshSelfEntry(cfg, "online")
    if selfEntry then
        selfEntry.local_version = state.updates.controller_version
    end

    -- Timers
    local display_timer   = os.startTimer(DISPLAY_INTERVAL)
    local alert_timer     = os.startTimer(5)
    local rollout_timer   = os.startTimer(1)
    local auto_check_timer = os.startTimer(2)
    local runtime_action = nil

    -- Message receive loop + HUD event loop run in parallel
    local function net_loop()
        while true do
            local msg = net.receive(DISPLAY_INTERVAL + 1, {
                net.MSG.NODE_HELLO,
                net.MSG.MATRIX_DATA,
                net.MSG.REACTOR_DATA,
                net.MSG.POCKET_REQUEST,
                net.MSG.UPDATE_ACK,
                net.MSG.UPDATE_STATUS,
            })
            if msg then
                if     msg.type == net.MSG.NODE_HELLO     then onNodeHello(msg, cfg)
                elseif msg.type == net.MSG.MATRIX_DATA    then onMatrixData(msg, cfg)
                elseif msg.type == net.MSG.REACTOR_DATA   then onReactorData(msg, cfg)
                elseif msg.type == net.MSG.POCKET_REQUEST then onPocketRequest(msg, cfg)
                elseif msg.type == net.MSG.UPDATE_ACK     then onUpdateAck(msg, cfg)
                elseif msg.type == net.MSG.UPDATE_STATUS  then onUpdateStatus(msg, cfg)
                end
                refreshPanel(cfg)
                hud.update(buildDisplayPayload())
            end
        end
    end

    local function timer_loop()
        while true do
            local _, id = os.pullEvent("timer")
            if id == display_timer then
                refreshSelfEntry(cfg, "online")
                -- Periodic DISPLAY_UPDATE broadcast
                net.send(net.MSG.DISPLAY_UPDATE, buildDisplayPayload())
                -- Refresh staleness-based alerts
                updateAlerts(cfg)
                refreshPanel(cfg)
                hud.update(buildDisplayPayload())
                display_timer = os.startTimer(DISPLAY_INTERVAL)
            elseif id == alert_timer then
                playAlerts(speaker, cfg)
                rotateAlert()
                refreshPanel(cfg)
                alert_timer = os.startTimer(5)
            elseif id == rollout_timer then
                tickRollout(cfg)
                rollout_timer = os.startTimer(1)
            elseif id == auto_check_timer then
                if not state.updates.offer and not state.updates.rollout and not state.updates.check_deadline then
                    performUpdateCheck(cfg, false)
                end
                auto_check_timer = os.startTimer(getAutoCheckInterval(cfg))
            end
        end
    end

    local function key_loop()
        while true do
            local _, key = os.pullEvent("key")
            if runtime_ui and runtime_ui.handleKey(key) then
            elseif key == keys.f2 then
                runtime_action = "config"
                return
            elseif key == keys.f4 then
                hud.toggleView()
            elseif key == keys.f5 then
                performUpdateCheck(cfg, false)
            elseif key == keys.f6 then
                createUpdateOffer(cfg, nil)
            elseif key == keys.f7 then
                startUpdateOffer(cfg)
            elseif key == keys.f8 then
                abortUpdateFlow(cfg)
            elseif key == keys.f9 then
                updateSelf(cfg)
            end
        end
    end

    local function mouse_loop()
        while true do
            local _, direction = os.pullEvent("mouse_scroll")
            if runtime_ui then
                runtime_ui.handleMouseScroll(direction)
            end
        end
    end

    -- Basalt's run() drives its own event loop. We interleave it with our
    -- network/timer loops via parallel.
    local function hud_loop()
        hud.run()
    end

    parallel.waitForAny(net_loop, timer_loop, hud_loop, key_loop, mouse_loop)

    if runtime_action == "config" then
        runtime_actions.openConfigEditor(cfg, logLine)
    end
end

return controller
