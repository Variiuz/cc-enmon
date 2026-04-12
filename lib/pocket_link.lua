local identity = require("lib/node_identity")

local pocket_link = {}

local function cloneTable(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

function pocket_link.buildRequestPayload(cfg, sender_id)
    return identity.decorateTelemetry(cfg, "pocket", { from = sender_id })
end

function pocket_link.buildTargetedPayload(payload, sender_id)
    local copy = cloneTable(payload)
    copy.for_sender = sender_id
    return copy
end

function pocket_link.acceptPayload(payload, sender_id)
    payload = payload or {}
    return payload.for_sender == nil or payload.for_sender == sender_id
end

return pocket_link