local controller_link = require("lib/controller_link")
local net = require("lib/network")
local updater = require("lib/updater")
local version = require("lib/version")

local UPDATE_ORDER = {
    display = 1,
    pocket = 2,
    matrix = 3,
    reactor = 4,
    controller = 5,
}

local updates = {}

function updates.new(opts)
    local state = assert(opts.state, "state is required")
    local now = assert(opts.now, "now is required")
    local isStale = assert(opts.isStale, "isStale is required")
    local logLine = assert(opts.logLine, "logLine is required")
    local refreshPanel = assert(opts.refreshPanel, "refreshPanel is required")
    local sendToNode = assert(opts.sendToNode, "sendToNode is required")
    local sendToEntry = assert(opts.sendToEntry, "sendToEntry is required")
    local rememberNode = assert(opts.rememberNode, "rememberNode is required")
    local refreshSelfEntry = assert(opts.refreshSelfEntry, "refreshSelfEntry is required")
    local compareVersion = assert(opts.compareVersion, "compareVersion is required")
    local reportNodeChange = assert(opts.reportNodeChange, "reportNodeChange is required")
    local check_timeout = assert(opts.check_timeout, "check_timeout is required")
    local update_timeout = assert(opts.update_timeout, "update_timeout is required")

    local api = {}

    local function rolloutRank(entry)
        return UPDATE_ORDER[entry.role] or 99
    end

    local function sortQueue(queue)
        table.sort(queue, function(left, right)
            local left_rank = rolloutRank(left)
            local right_rank = rolloutRank(right)
            if left_rank == right_rank then
                return tostring(left.node_id) < tostring(right.node_id)
            end
            return left_rank < right_rank
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

    function api.reconcileNode(entry, cfg, source)
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

    function api.effectiveNodeStatus(entry)
        if not entry then return "unknown" end
        if entry.unlinked then return "unlinked" end
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

    function api.blockMismatchedOperationalNode(entry, kind)
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

    function api.controllerNeedsReviewUpdate(cfg)
        local entry = controllerEntry(cfg)
        if entry and entry.needs_update == true then
            return true, entry
        end
        return false, entry
    end

    function api.ensureControllerCurrentForRemoteUpdates(cfg)
        if rolloutPolicy() ~= "controller-first" then
            return true
        end

        if not state.updates.latest_version then
            local ok = api.performUpdateCheck(cfg, false)
            if not ok then
                return false
            end
        end

        local needs_update = api.controllerNeedsReviewUpdate(cfg)
        if needs_update then
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
            return tostring(entry.node_id), buildVersionPath(entry.local_version or "--", state.updates.latest_version, entry.needs_update == true) .. "  " .. tostring(api.effectiveNodeStatus(entry))
        end

        if state.updates.latest_version then
            return "All", "Current @ " .. tostring(state.updates.latest_version)
        end

        return "--", "--"
    end

    function api.buildRuntimeUpdatesLine(cfg)
        local controller_needs_update = api.controllerNeedsReviewUpdate(cfg)
        local controller_path = buildVersionPath(
            state.updates.controller_version or "--",
            state.updates.latest_version,
            controller_needs_update == true
        )
        local update_node, update_path = buildRuntimeUpdateSummary(cfg)

        if update_node == "--" or update_path == "--" then
            return controller_path
        end

        if update_node == "All" then
            return controller_path .. " | " .. update_path
        end

        return controller_path .. " | " .. tostring(update_node) .. " " .. tostring(update_path)
    end

    function api.buildUpdateSnapshot()
        local updates_state = state.updates
        local counts = {
            queued = 0,
            pending_offline = 0,
            unlinked = 0,
            identity_conflict = 0,
            wrong_controller = 0,
            offered = 0,
        }
        local nodes = {}

        for node_id, entry in pairs(updates_state.nodes) do
            local status = api.effectiveNodeStatus(entry)
            if status == "queued" then counts.queued = counts.queued + 1 end
            if status == "pending-offline" then counts.pending_offline = counts.pending_offline + 1 end
            if status == "unlinked" then counts.unlinked = counts.unlinked + 1 end
            if status == "identity-conflict" then counts.identity_conflict = counts.identity_conflict + 1 end
            if status == "wrong-controller" then counts.wrong_controller = counts.wrong_controller + 1 end
            if status == "offered" then counts.offered = counts.offered + 1 end

            nodes[#nodes + 1] = {
                node_id = node_id,
                role = entry.role or "unknown",
                sender_id = entry.sender_id,
                local_version = entry.local_version or "--",
                version_display = buildVersionPath(entry.local_version or "--", updates_state.latest_version, entry.needs_update == true),
                target_version = updates_state.latest_version,
                status = status,
                needs_update = entry.needs_update == true,
                stale = isStale(entry.last_seen or 0),
                note = entry.message or entry.node_status or (entry.role == "controller" and "Review controller update here, then apply locally with F9 on the controller terminal" or nil),
            }
        end

        table.sort(nodes, function(left, right)
            local left_rank = rolloutRank(left)
            local right_rank = rolloutRank(right)
            if left_rank == right_rank then
                return tostring(left.node_id) < tostring(right.node_id)
            end
            return left_rank < right_rank
        end)

        local phase = "idle"
        if updates_state.offer then
            phase = "offer"
        elseif updates_state.rollout then
            phase = updates_state.rollout.cancelled and "aborting" or "rollout"
        end

        return {
            controller_version = updates_state.controller_version,
            latest_version = updates_state.latest_version,
            rollout_policy = updates_state.rollout_policy,
            phase = phase,
            offer = updates_state.offer and {
                latest_version = updates_state.offer.latest_version,
                target_count = #updates_state.offer.queue,
                pending_count = updates_state.offer.pending_count or 0,
            } or nil,
            rollout = updates_state.rollout and {
                current = updates_state.rollout.current and updates_state.rollout.current.node_id or nil,
                queued = #updates_state.rollout.queue,
                cancelled = updates_state.rollout.cancelled == true,
            } or nil,
            counts = counts,
            nodes = nodes,
        }
    end

    local function collectOfferTargets(cfg, target_node_id)
        local queue = {}
        local pending = {}
        local found_target = target_node_id == nil

        for node_id, entry in pairs(state.updates.nodes) do
            if node_id ~= cfg.get("node_id") and entry.role ~= "controller" and entry.sender_id and not entry.unlinked then
                if target_node_id == nil or node_id == target_node_id then
                    found_target = true
                    if entry.controller_mismatch then
                        entry.update_status = "wrong-controller"
                    elseif entry.identity_conflict then
                        entry.update_status = "identity-conflict"
                    else
                        local needs_update = entry.needs_update
                        if state.updates.force then
                            needs_update = true
                        elseif needs_update == nil and entry.local_version and state.updates.latest_version then
                            needs_update = version.isNewer(state.updates.latest_version, entry.local_version)
                        end
                        if needs_update then
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
        return found_target, queue, pending
    end

    function api.createUpdateOffer(cfg, target_node_id)
        if state.updates.rollout then
            logLine("[ctrl] Cannot create a new offer while rollout is active", colors.orange)
            return false
        end
        if target_node_id and target_node_id == cfg.get("node_id") then
            logLine("[ctrl] Controller updates are local-only via enmon-cli update", colors.orange)
            return false
        end
        if not api.ensureControllerCurrentForRemoteUpdates(cfg) then
            return false
        end

        local found_target, queue, pending = collectOfferTargets(cfg, target_node_id)
        if not found_target then
            logLine("[ctrl] Selected node not found", colors.orange)
            return false
        end
        if #queue == 0 and next(pending) == nil then
            logLine("[ctrl] No eligible nodes to offer an update", colors.orange)
            return false
        end

        local offer = {
            latest_version = state.updates.latest_version,
            force = state.updates.force == true,
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
            local entry = state.updates.nodes[item.node_id]
            local _, _, msg_id = sendToNode(item.node_id, item.sender_id, net.MSG.UPDATE_OFFER, {
                desired_version = offer.latest_version,
                force = offer.force,
            })
            offer.msg_ids[item.node_id] = msg_id
            if entry then entry.update_status = "offered" end
        end

        state.updates.offer = offer
        logLine("[ctrl] Update offer prepared for " .. tostring(#queue) .. " node(s)", colors.lime)
        refreshPanel(cfg)
        return true
    end

    function api.startUpdateOffer(cfg)
        local offer = state.updates.offer
        if not offer then
            logLine("[ctrl] No pending update offer", colors.orange)
            return false
        end

        if not api.ensureControllerCurrentForRemoteUpdates(cfg) then
            state.updates.offer = nil
            refreshPanel(cfg)
            return false
        end

        state.updates.rollout = {
            queue = offer.queue,
            queued = {},
            pending = offer.pending,
            latest_version = offer.latest_version,
            force = offer.force == true,
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

    function api.abortUpdateFlow(cfg)
        local aborted_any = false
        state.updates.last_abort_ids = {}

        if state.updates.offer then
            for _, item in ipairs(state.updates.offer.queue) do
                local _, _, msg_id = sendToNode(item.node_id, item.sender_id, net.MSG.UPDATE_ABORT, {
                    reason = "operator-cancelled",
                })
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
                local _, _, msg_id = sendToNode(item.node_id, item.sender_id, net.MSG.UPDATE_ABORT, {
                    reason = "operator-cancelled",
                })
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
                    local _, _, msg_id = sendToEntry(current, net.MSG.UPDATE_ABORT, {
                        reason = "operator-cancelled",
                    })
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

    function api.adoptReplacement(cfg, node_id)
        if not node_id or node_id == "" then
            logLine("[ctrl] Select a node to adopt", colors.orange)
            return false
        end

        local entry = state.updates.nodes[node_id]
        if not entry then
            logLine("[ctrl] Node not found: " .. tostring(node_id), colors.orange)
            return false
        end
        if not entry.unlinked and not entry.identity_conflict then
            logLine("[ctrl] Node is not waiting for adoption or replace", colors.orange)
            return false
        end

        local target_sender = entry.pending_sender_id or entry.sender_id
        if not target_sender then
            logLine("[ctrl] Node has no live sender yet; wait for discovery", colors.orange)
            return false
        end

        local replacing = controller_link.hasStoredToken(entry.node_id)
        if replacing then
            logLine("[ctrl] Node already has a token; confirm replace on the terminal", colors.orange)
            if not controller_link.promptYesNo("Replace existing link for " .. tostring(node_id) .. "?", false) then
                logLine("[ctrl] Replace cancelled", colors.orange)
                return false
            end
        end

        logLine("[ctrl] Enter claim code from the node screen on the terminal", colors.lightBlue)
        local claim_code = controller_link.promptClaimCode(
            "Claim code for " .. tostring(node_id) .. " (shown on that computer, not on the network):"
        )
        if not claim_code then
            logLine("[ctrl] Adoption cancelled: empty claim code", colors.orange)
            return false
        end

        local token, token_err = controller_link.issueNodeToken(entry.node_id, target_sender, entry.role, {
            replace = replacing,
        })
        if not token then
            logLine("[ctrl] Failed to issue node token: " .. tostring(token_err), colors.red)
            return false
        end

        local wrapped = controller_link.wrapAdoptToken(token, claim_code, entry.node_id, target_sender)
        if not wrapped then
            logLine("[ctrl] Failed to wrap adopt token", colors.red)
            return false
        end

        local ok, err = net.sendTargeted(net.MSG.ADOPT_REQUEST, controller_link.buildControllerPayload(entry.node_id, {
            wrapped_token = wrapped,
            wrap_v = 1,
        }), entry.node_id, target_sender, nil, {
            auth_key = claim_code,
        })
        if not ok then
            logLine("[ctrl] Failed to send adoption request: " .. tostring(err), colors.red)
            return false
        end

        entry.sender_id = target_sender
        entry.pending_sender_id = nil
        entry.controller_id = os.getComputerID()
        entry.controller_mismatch = false
        entry.identity_conflict = false
        entry.update_status = "adopting"
        entry.message = "Adoption sent; waiting for secure hello"
        logLine("[ctrl] Adoption request sent to " .. tostring(node_id) .. " (claim kept off-wire)", colors.lime)
        refreshPanel(cfg)
        return true
    end

    function api.performUpdateCheck(cfg, force)
        force = force == true
        local info, err = updater.checkForUpdate(cfg.get("role"), nil, force)
        if not info then
            logLine("[ctrl] Update check failed: " .. tostring(err), colors.red)
            return false
        end

        state.updates.controller_version = info.current_version
        state.updates.latest_version = info.latest_version
        state.updates.rollout_policy = info.rollout_policy or version.getRolloutPolicy()
        state.updates.force = force

        local self_entry = refreshSelfEntry(cfg, "online")
        if self_entry then
            self_entry.local_version = info.current_version
            self_entry.needs_update = info.needs_update
            self_entry.update_status = info.needs_update and "ready" or "online-current"
        end

        logLine("[ctrl] Latest manifest version: " .. tostring(info.latest_version) .. " (local " .. tostring(info.current_version) .. ", policy " .. tostring(state.updates.rollout_policy or "controller-first") .. (force and ", force" or "") .. ")", colors.lightBlue)
        state.updates.last_check_ids = {}
        for node_id, entry in pairs(state.updates.nodes) do
            if node_id ~= cfg.get("node_id") and entry.sender_id and not entry.unlinked then
                local _, _, msg_id = sendToEntry(entry, net.MSG.UPDATE_CHECK, {
                    desired_version = info.latest_version,
                    force = force,
                })
                state.updates.last_check_ids[node_id] = msg_id
            end
        end
        state.updates.check_deadline = now() + check_timeout
        for node_id, entry in pairs(state.updates.nodes) do
            if node_id ~= cfg.get("node_id") and not entry.unlinked then
                entry.needs_update = nil
                if not isStale(entry.last_seen or 0) then
                    entry.update_status = "checking"
                end
            end
        end
        refreshPanel(cfg)
        return true
    end

    function api.startRollout(cfg)
        if state.updates.rollout then
            logLine("[ctrl] Update rollout already running", colors.orange)
            return
        end
        if not api.ensureControllerCurrentForRemoteUpdates(cfg) then
            return
        end

        local queue = {}
        for node_id, entry in pairs(state.updates.nodes) do
            if node_id ~= cfg.get("node_id") and entry.role ~= "controller" and entry.sender_id and not entry.unlinked then
                if entry.controller_mismatch then
                    entry.update_status = "wrong-controller"
                elseif entry.identity_conflict then
                    entry.update_status = "identity-conflict"
                else
                    local needs_update = entry.needs_update
                    if needs_update == nil and entry.local_version and state.updates.latest_version then
                        needs_update = version.isNewer(state.updates.latest_version, entry.local_version)
                    end
                    if needs_update then
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

    function api.tickRollout(cfg)
        if state.updates.check_deadline and now() >= state.updates.check_deadline then
            state.updates.check_deadline = nil
            state.updates.last_check_ids = {}
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

        local next_node = table.remove(rollout.queue, 1)
        if not next_node then
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

        local live = state.updates.nodes[next_node.node_id]
        if not live or not live.sender_id or isStale(live.last_seen or 0) then
            logLine("[ctrl] Skipping offline node: " .. tostring(next_node.node_id), colors.orange)
            rollout.pending[next_node.node_id] = "offline"
            rollout.queued[next_node.node_id] = nil
            return
        end
        if live.controller_mismatch or live.identity_conflict then
            logLine("[ctrl] Skipping conflicted node: " .. tostring(next_node.node_id), colors.orange)
            rollout.pending[next_node.node_id] = live.controller_mismatch and "wrong-controller" or "identity-conflict"
            rollout.queued[next_node.node_id] = nil
            return
        end

        logLine("[ctrl] Starting update on " .. tostring(next_node.node_id) .. " (" .. tostring(next_node.role) .. ")", colors.lightBlue)
        local _, _, msg_id = sendToNode(next_node.node_id, next_node.sender_id, net.MSG.UPDATE_START, {
            desired_version = rollout.latest_version,
            force = rollout.force == true,
        })

        live.update_status = "starting"
        rollout.queued[next_node.node_id] = nil
        rollout.current = {
            node_id = next_node.node_id,
            msg_id = msg_id,
            deadline = now() + update_timeout,
        }
        refreshPanel(cfg)
    end

    function api.handleUpdateAck(msg, cfg)
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

    function api.handleUpdateStatus(msg, cfg)
        local payload = msg.payload or {}
        if payload.phase == "check" and msg.msg_id ~= state.updates.last_check_ids[msg.node_id] then
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
            api.reconcileNode(entry, cfg, "check")
        elseif payload.phase == "offer" then
            if entry then entry.update_status = payload.status or "offered" end
        elseif payload.phase == "abort" then
            if entry then entry.update_status = payload.status or "aborted" end
        elseif rollout and rollout.current and rollout.current.node_id == msg.node_id then
            if payload.status == "success" or payload.status == "failed" or payload.status == "noop" then
                rollout.current = nil
            elseif payload.status == "in_progress" then
                rollout.current.deadline = now() + update_timeout
            end
        end

        api.reconcileNode(entry, cfg, payload.phase or "status")
        refreshPanel(cfg)
    end

    function api.updateSelf(cfg)
        if state.updates.rollout then
            logLine("[ctrl] Finish remote rollout before self-update", colors.orange)
            return
        end

        if not state.updates.latest_version then
            local ok = api.performUpdateCheck(cfg, false)
            if not ok then
                return
            end
            local needs_update = api.controllerNeedsReviewUpdate(cfg)
            if needs_update then
                logLine("[ctrl] Review controller update in the Updates view, then press F9 again to apply", colors.lightBlue)
                refreshPanel(cfg)
                return
            end
        end

        local needs_update = api.controllerNeedsReviewUpdate(cfg)
        if not needs_update then
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

    return api
end

return updates