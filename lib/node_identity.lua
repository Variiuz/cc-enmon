-- lib/node_identity.lua
-- Shared node identity announcements and telemetry decoration.

local net = require("lib/network")
local version = require("lib/version")

local identity = {}

local function cfgGet(cfg, key)
    if type(cfg.get) == "function" then
        return cfg.get(key)
    end
    if type(cfg) == "table" then
        return cfg[key]
    end
    return nil
end

function identity.announce(cfg, role, status, extra)
    local payload = {
        role = role or cfgGet(cfg, "role"),
        local_version = version.getVersion(),
        status = status or "online",
        controller_id = cfgGet(cfg, "controller_id"),
    }

    for key, value in pairs(extra or {}) do
        payload[key] = value
    end

    return net.send(net.MSG.NODE_HELLO, payload)
end

function identity.decorateTelemetry(role, payload)
    payload = payload or {}
    payload.role = role
    payload.version = version.getVersion()
    return payload
end

return identity