-- lib/update_service.lua
-- Shared node-side handling for controller-coordinated updates.

local net = require("lib/network")
local controller_link = require("lib/controller_link")
local updater = require("lib/updater")
local version = require("lib/version")

local service = {}
local SERVICE_STATE_PATH = ".enmon_update_service_state"
local UPDATER_SENTINEL_PATH = ".enmon_update_state"
local UPDATER_STAGE_DIR = ".enmon_update_stage"
local pending_offer = nil
local update_in_progress = false
local active_cfg = nil

local function readServiceState()
    if not fs.exists(SERVICE_STATE_PATH) then
        return { pending_offer = nil, update_in_progress = false }
    end

    local file = fs.open(SERVICE_STATE_PATH, "r")
    if not file then
        return { pending_offer = nil, update_in_progress = false }
    end

    local raw = file.readAll()
    file.close()

    local ok, parsed = pcall(textutils.unserialize, raw)
    if not ok or type(parsed) ~= "table" then
        fs.delete(SERVICE_STATE_PATH)
        return { pending_offer = nil, update_in_progress = false }
    end

    local state = {
        pending_offer = type(parsed.pending_offer) == "table" and parsed.pending_offer or nil,
        update_in_progress = parsed.update_in_progress == true,
    }

    if state.pending_offer then
        if type(state.pending_offer.desired_version) ~= "string" then state.pending_offer = nil end
        if state.pending_offer and type(state.pending_offer.sender_id) ~= "number" then state.pending_offer = nil end
        if state.pending_offer and type(state.pending_offer.force) ~= "boolean" then state.pending_offer.force = false end
    end

    if state.update_in_progress and not fs.exists(UPDATER_SENTINEL_PATH) and not fs.exists(UPDATER_STAGE_DIR) then
        state.update_in_progress = false
    end

    return state
end

local function writeServiceState()
    if not pending_offer and not update_in_progress then
        if fs.exists(SERVICE_STATE_PATH) then fs.delete(SERVICE_STATE_PATH) end
        return
    end

    local file = fs.open(SERVICE_STATE_PATH, "w")
    if not file then return end
    file.write(textutils.serialize({
        pending_offer = pending_offer,
        update_in_progress = update_in_progress,
    }))
    file.close()
end

do
    local state = readServiceState()
    pending_offer = state.pending_offer
    update_in_progress = state.update_in_progress
    writeServiceState()
end

local function cfgGet(cfg, key)
    if type(cfg.get) == "function" then
        return cfg.get(key)
    end
    if type(cfg) == "table" then
        return cfg[key]
    end
    return nil
end

local function logLine(logger, message)
    if type(logger) == "function" then
        logger(message)
    end
end

local function sendReply(msgType, payload, sourceMsg)
    controller_link.sendNodeTargeted(active_cfg or {}, msgType, payload, sourceMsg.node_id, sourceMsg.sender_id, sourceMsg.msg_id)
end

function service.handleMessage(cfg, msg, logger)
    if not msg or (
        msg.type ~= net.MSG.UPDATE_CHECK and
        msg.type ~= net.MSG.UPDATE_OFFER and
        msg.type ~= net.MSG.UPDATE_START and
        msg.type ~= net.MSG.UPDATE_ABORT
    ) then
        return false
    end
    if not net.isTargetedToSelf(msg) then
        return false
    end

    active_cfg = cfg

    local role = cfgGet(cfg, "role")
    local currentVersion = version.getVersion()

    if role ~= "controller" and not controller_link.isAdopted(cfg) then
        logLine(logger, "[update] Ignoring update command because this node has not been adopted")
        return true
    end

    if not controller_link.validateControllerMessage(cfg, msg, logger) then
        return true
    end

    if msg.type == net.MSG.UPDATE_CHECK then
        local desired = msg.payload and msg.payload.desired_version or nil
        local forceUpdate = msg.payload and msg.payload.force == true or false
        local needsUpdate = forceUpdate or (type(desired) == "string" and version.isNewer(desired, currentVersion) or false)
        sendReply(net.MSG.UPDATE_STATUS, {
            phase = "check",
            status = "ready",
            role = role,
            local_version = currentVersion,
            desired_version = desired,
            needs_update = needsUpdate,
            force = forceUpdate,
        }, msg)
        logLine(logger, "[update] Reported version " .. currentVersion .. " to controller")
        return true
    end

    if msg.type == net.MSG.UPDATE_OFFER then
        local desired = msg.payload and msg.payload.desired_version or nil
        local forceUpdate = msg.payload and msg.payload.force == true or false
        pending_offer = {
            desired_version = desired,
            sender_id = msg.sender_id,
            node_id = msg.node_id,
            force = forceUpdate,
        }
        writeServiceState()
        sendReply(net.MSG.UPDATE_STATUS, {
            phase = "offer",
            status = "offered",
            role = role,
            local_version = currentVersion,
            desired_version = desired,
            needs_update = forceUpdate or (type(desired) == "string" and version.isNewer(desired, currentVersion) or false),
            force = forceUpdate,
        }, msg)
        logLine(logger, "[update] Offer received for version " .. tostring(desired) .. (forceUpdate and " (force)" or ""))
        return true
    end

    if msg.type == net.MSG.UPDATE_ABORT then
        if update_in_progress then
            sendReply(net.MSG.UPDATE_STATUS, {
                phase = "abort",
                status = "cannot-abort",
                role = role,
                local_version = currentVersion,
            }, msg)
            logLine(logger, "[update] Abort requested but update is already in progress")
            return true
        end

        pending_offer = nil
        writeServiceState()
        sendReply(net.MSG.UPDATE_STATUS, {
            phase = "abort",
            status = "aborted",
            role = role,
            local_version = currentVersion,
        }, msg)
        logLine(logger, "[update] Pending offer aborted")
        return true
    end

    local desiredVersion = msg.payload and msg.payload.desired_version or nil
    local forceUpdate = msg.payload and msg.payload.force == true or false
    if update_in_progress then
        sendReply(net.MSG.UPDATE_STATUS, {
            phase = "start",
            status = "in_progress",
            role = role,
            local_version = currentVersion,
            desired_version = desiredVersion,
            force = forceUpdate,
        }, msg)
        logLine(logger, "[update] Rejecting start because an update is already in progress")
        return true
    end
    if not pending_offer or pending_offer.sender_id ~= msg.sender_id or pending_offer.desired_version ~= desiredVersion or pending_offer.force ~= forceUpdate then
        sendReply(net.MSG.UPDATE_STATUS, {
            phase = "start",
            status = "rejected-no-offer",
            role = role,
            local_version = currentVersion,
            desired_version = desiredVersion,
            force = forceUpdate,
        }, msg)
        logLine(logger, "[update] Rejecting start without matching offer")
        return true
    end

    pending_offer = nil
    update_in_progress = true
    writeServiceState()

    sendReply(net.MSG.UPDATE_ACK, {
        command = net.MSG.UPDATE_START,
        status = "accepted",
        role = role,
        local_version = currentVersion,
    }, msg)
    sendReply(net.MSG.UPDATE_STATUS, {
        phase = "download",
        status = "in_progress",
        role = role,
        local_version = currentVersion,
        force = forceUpdate,
    }, msg)
    logLine(logger, "[update] Starting self-update" .. (forceUpdate and " (force)" or ""))

    local ok, result = updater.applyLocalUpdate({
        role = role,
        force = forceUpdate,
        logger = function(line)
            logLine(logger, "[update] " .. tostring(line))
        end,
    })

    if not ok then
        update_in_progress = false
        writeServiceState()
        sendReply(net.MSG.UPDATE_STATUS, {
            phase = "error",
            status = "failed",
            role = role,
            local_version = currentVersion,
            message = tostring(result),
            force = forceUpdate,
        }, msg)
        logLine(logger, "[update] Update failed: " .. tostring(result))
        return true
    end

    if not result.updated then
        update_in_progress = false
        writeServiceState()
        sendReply(net.MSG.UPDATE_STATUS, {
            phase = "complete",
            status = "noop",
            role = role,
            local_version = result.current_version,
            desired_version = result.latest_version,
            force = forceUpdate,
        }, msg)
        logLine(logger, "[update] Already on latest version")
        return true
    end

    update_in_progress = false
    writeServiceState()
    sendReply(net.MSG.UPDATE_STATUS, {
        phase = "complete",
        status = "success",
        role = role,
        local_version = result.to_version,
        from_version = result.from_version,
        to_version = result.to_version,
        force = forceUpdate,
    }, msg)
    logLine(logger, "[update] Update complete: " .. tostring(result.from_version) .. " -> " .. tostring(result.to_version))

    os.sleep(0.2)
    os.reboot()
    return true
end

return service