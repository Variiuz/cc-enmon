-- lib/node_identity.lua
-- Shared node identity announcements and telemetry decoration.

local net = require("lib/network")
local controller_link = require("lib/controller_link")
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
        adopted = controller_link.isAdopted(cfg),
    }

    for key, value in pairs(extra or {}) do
        payload[key] = value
    end

    if controller_link.isAdopted(cfg) or cfgGet(cfg, "role") == "controller" then
        return controller_link.sendNodeMessage(cfg, net.MSG.NODE_HELLO, payload)
    end

    return controller_link.sendDiscovery(cfg, role, payload.claim_code, payload)
end

function identity.decorateTelemetry(cfg, role, payload)
    if cfgGet(cfg, "role") ~= "controller" and not controller_link.isAdopted(cfg) then
        return nil
    end
    local data = controller_link.decorateNodePayload(cfg, payload or {})
    data.role = role
    data.version = version.getVersion()
    data.adopted = controller_link.isAdopted(cfg)
    return data
end

return identity