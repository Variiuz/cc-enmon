-- lib/update_service.lua
-- Shared node-side handling for controller-coordinated updates.

local net = require("lib/network")
local updater = require("lib/updater")
local version = require("lib/version")

local service = {}
local pending_offer = nil
local update_in_progress = false

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
    net.sendTargeted(msgType, payload, sourceMsg.node_id, sourceMsg.sender_id, nil, sourceMsg.msg_id)
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

    local role = cfgGet(cfg, "role")
    local controllerId = cfgGet(cfg, "controller_id")
    local currentVersion = version.getVersion()

    if role ~= "controller" and controllerId ~= nil and msg.sender_id ~= controllerId then
        logLine(logger, "[update] Ignoring update command from unknown sender: " .. tostring(msg.sender_id))
        return true
    end

    if msg.type == net.MSG.UPDATE_CHECK then
        local desired = msg.payload and msg.payload.desired_version or nil
        local needsUpdate = type(desired) == "string" and version.isNewer(desired, currentVersion) or false
        sendReply(net.MSG.UPDATE_STATUS, {
            phase = "check",
            status = "ready",
            role = role,
            local_version = currentVersion,
            desired_version = desired,
            needs_update = needsUpdate,
        }, msg)
        logLine(logger, "[update] Reported version " .. currentVersion .. " to controller")
        return true
    end

    if msg.type == net.MSG.UPDATE_OFFER then
        local desired = msg.payload and msg.payload.desired_version or nil
        pending_offer = {
            desired_version = desired,
            sender_id = msg.sender_id,
            node_id = msg.node_id,
        }
        sendReply(net.MSG.UPDATE_STATUS, {
            phase = "offer",
            status = "offered",
            role = role,
            local_version = currentVersion,
            desired_version = desired,
            needs_update = type(desired) == "string" and version.isNewer(desired, currentVersion) or false,
        }, msg)
        logLine(logger, "[update] Offer received for version " .. tostring(desired))
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
    if not pending_offer or pending_offer.sender_id ~= msg.sender_id or pending_offer.desired_version ~= desiredVersion then
        sendReply(net.MSG.UPDATE_STATUS, {
            phase = "start",
            status = "rejected-no-offer",
            role = role,
            local_version = currentVersion,
            desired_version = desiredVersion,
        }, msg)
        logLine(logger, "[update] Rejecting start without matching offer")
        return true
    end

    pending_offer = nil
    update_in_progress = true

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
    }, msg)
    logLine(logger, "[update] Starting self-update")

    local ok, result = updater.applyLocalUpdate({
        role = role,
        logger = function(line)
            logLine(logger, "[update] " .. tostring(line))
        end,
    })

    if not ok then
        update_in_progress = false
        sendReply(net.MSG.UPDATE_STATUS, {
            phase = "error",
            status = "failed",
            role = role,
            local_version = currentVersion,
            message = tostring(result),
        }, msg)
        logLine(logger, "[update] Update failed: " .. tostring(result))
        return true
    end

    if not result.updated then
        update_in_progress = false
        sendReply(net.MSG.UPDATE_STATUS, {
            phase = "complete",
            status = "noop",
            role = role,
            local_version = result.current_version,
            desired_version = result.latest_version,
        }, msg)
        logLine(logger, "[update] Already on latest version")
        return true
    end

    update_in_progress = false
    sendReply(net.MSG.UPDATE_STATUS, {
        phase = "complete",
        status = "success",
        role = role,
        local_version = result.to_version,
        from_version = result.from_version,
        to_version = result.to_version,
    }, msg)
    logLine(logger, "[update] Update complete: " .. tostring(result.from_version) .. " -> " .. tostring(result.to_version))

    os.sleep(0.2)
    os.reboot()
    return true
end

return service