local net = require("lib/network")
local version = require("lib/version")

local link = {}

local TOKEN_STORE_PATH = ".enmon_controller_tokens"
local TOKEN_BYTES = 16
local CLAIM_CODE_BYTES = 3
local token_store = nil

local function cfgGet(cfg, key)
    if type(cfg.get) == "function" then
        return cfg.get(key)
    end
    if type(cfg) == "table" then
        return cfg[key]
    end
    return nil
end

local function cfgSet(cfg, key, value)
    if type(cfg.set) == "function" then
        cfg.set(key, value)
        return true
    end
    if type(cfg) == "table" then
        cfg[key] = value
        return true
    end
    return false
end

local function cfgSave(cfg)
    if type(cfg.save) == "function" then
        cfg.save()
    end
end

local function cloneTable(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

local function logLine(logger, message)
    if type(logger) == "function" then
        logger(message)
    end
end

local function readTokenStore()
    if not fs.exists(TOKEN_STORE_PATH) then
        return {}
    end

    local file = fs.open(TOKEN_STORE_PATH, "r")
    if not file then
        return {}
    end

    local raw = file.readAll()
    file.close()

    local ok, parsed = pcall(textutils.unserialize, raw)
    if not ok or type(parsed) ~= "table" then
        return {}
    end

    local store = {}
    for node_id, entry in pairs(parsed) do
        if type(node_id) == "string" and type(entry) == "table" and type(entry.token) == "string" and entry.token ~= "" then
            store[node_id] = {
                token = entry.token,
                sender_id = tonumber(entry.sender_id),
                issued_at = tonumber(entry.issued_at) or 0,
            }
        end
    end
    return store
end

local function writeTokenStore(store)
    local file = fs.open(TOKEN_STORE_PATH, "w")
    if not file then return false end
    file.write(textutils.serialize(store or {}))
    file.close()
    return true
end

local function getTokenStore()
    if token_store == nil then
        token_store = readTokenStore()
    end
    return token_store
end

local function randomHex(bytes)
    local chunks = {}
    for index = 1, bytes do
        chunks[index] = string.format("%02x", math.random(0, 255))
    end
    return table.concat(chunks)
end

local function getStoredEntry(node_id)
    if type(node_id) ~= "string" or node_id == "" then
        return nil
    end
    return getTokenStore()[node_id]
end

function link.newClaimCode()
    return string.upper(randomHex(CLAIM_CODE_BYTES))
end

function link.isAdopted(cfg)
    if cfgGet(cfg, "role") == "controller" then
        return true
    end
    return type(cfgGet(cfg, "controller_id")) == "number"
        and type(cfgGet(cfg, "controller_token")) == "string"
        and cfgGet(cfg, "controller_token") ~= ""
end

function link.decorateNodePayload(cfg, payload)
    local data = cloneTable(payload)
    if cfgGet(cfg, "role") ~= "controller" and link.isAdopted(cfg) then
        data.controller_id = cfgGet(cfg, "controller_id")
        data.adopted = true
    end
    return data
end

function link.buildDiscoveryPayload(cfg, role, claim_code, extra)
    local payload = cloneTable(extra)
    payload.role = role or cfgGet(cfg, "role")
    payload.local_version = version.getVersion()
    payload.status = payload.status or "unlinked"
    payload.claim_code = claim_code
    payload.adopted = false
    payload.controller_id = nil
    return payload
end

function link.getStoredToken(node_id)
    local entry = getStoredEntry(node_id)
    if entry then
        return entry.token
    end

    return nil
end

function link.storeNodeToken(node_id, sender_id, role, token)
    if type(node_id) ~= "string" or node_id == "" then return nil end
    if type(token) ~= "string" or token == "" then return nil end

    local store = getTokenStore()
    store[node_id] = {
        token = token,
        sender_id = tonumber(sender_id),
        role = role,
        adopted_at = os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000),
    }
    writeTokenStore(store)
    return token
end

function link.issueNodeToken(node_id, sender_id, role)
    return link.storeNodeToken(node_id, sender_id, role, randomHex(TOKEN_BYTES))
end

function link.buildControllerPayload(node_id, payload)
    local data = cloneTable(payload)
    data.controller_id = os.getComputerID()
    return data
end

function link.openControllerNetwork(cfg, modem)
    net.open(modem, cfgGet(cfg, "channel"), nil, cfgGet(cfg, "node_id"))
    net.setAuthResolver(function(msg)
        if msg.type == net.MSG.NODE_DISCOVERY or msg.type == net.MSG.ADOPT_REQUEST then
            return { allowUnauthenticated = true, required = false }
        end

        local entry = getStoredEntry(msg.node_id)
        if entry and (entry.sender_id == nil or entry.sender_id == msg.sender_id) then
            return { keys = { entry.token }, required = true }
        end

        return { required = true }
    end)
end

function link.openNodeNetwork(cfg, modem)
    net.open(modem, cfgGet(cfg, "channel"), nil, cfgGet(cfg, "node_id"))
    net.setAuthResolver(function(msg)
        if msg.type == net.MSG.ADOPT_REQUEST and not link.isAdopted(cfg) then
            return { allowUnauthenticated = true, required = false }
        end

        local token = cfgGet(cfg, "controller_token")
        if type(token) == "string" and token ~= "" then
            return { keys = { token }, required = true }
        end

        return { required = false }
    end)
end

function link.sendNodeMessage(cfg, msg_type, payload, target_channel, options)
    if cfgGet(cfg, "role") ~= "controller" and not link.isAdopted(cfg) and msg_type ~= net.MSG.NODE_DISCOVERY then
        return false, "node not adopted"
    end
    local sendOptions = cloneTable(options)
    if cfgGet(cfg, "role") ~= "controller" and link.isAdopted(cfg) then
        sendOptions.auth_key = cfgGet(cfg, "controller_token")
    end
    return net.send(msg_type, link.decorateNodePayload(cfg, payload), target_channel, sendOptions)
end

function link.sendNodeTargeted(cfg, msg_type, payload, target_node_id, target_sender_id, msg_id)
    if cfgGet(cfg, "role") ~= "controller" and not link.isAdopted(cfg) and msg_type ~= net.MSG.ADOPT_REQUEST then
        return false, "node not adopted"
    end
    local options = { msg_id = msg_id }
    if cfgGet(cfg, "role") ~= "controller" and link.isAdopted(cfg) then
        options.auth_key = cfgGet(cfg, "controller_token")
    end
    return net.sendTargeted(msg_type, link.decorateNodePayload(cfg, payload), target_node_id, target_sender_id, nil, options)
end

function link.sendDiscovery(cfg, role, claim_code, extra)
    return net.send(net.MSG.NODE_DISCOVERY, link.buildDiscoveryPayload(cfg, role, claim_code, extra))
end

function link.validateControllerMessage(cfg, msg, logger)
    if cfgGet(cfg, "role") == "controller" then
        return true
    end

    local controllerId = cfgGet(cfg, "controller_id")
    if controllerId ~= nil and msg.sender_id ~= controllerId then
        logLine(logger, "[auth] Ignoring controller message from unknown sender: " .. tostring(msg.sender_id))
        return false
    end

    if not link.isAdopted(cfg) and msg.type ~= net.MSG.ADOPT_REQUEST then
        logLine(logger, "[auth] Ignoring controller message before adoption")
        return false
    end

    return true
end

function link.validateNodeMessage(msg, logger)
    local token = link.getStoredToken(msg and msg.node_id)
    if not token and msg and msg.type ~= net.MSG.NODE_DISCOVERY then
        logLine(logger, "[auth] Ignoring unmanaged node message: " .. tostring(msg.node_id or "?"))
        return false
    end
    return true
end

function link.handleAdoptRequest(cfg, msg, claim_code, logger, onAdopted)
    if not msg or msg.type ~= net.MSG.ADOPT_REQUEST then
        return false
    end
    if not net.isTargetedToSelf(msg) then
        return false
    end

    local payload = type(msg.payload) == "table" and msg.payload or {}
    if type(payload.controller_id) ~= "number" or type(payload.controller_token) ~= "string" or payload.controller_token == "" then
        logLine(logger, "[adopt] Ignoring malformed adopt request")
        return true
    end
    if type(payload.claim_code) ~= "string" or payload.claim_code ~= claim_code then
        logLine(logger, "[adopt] Ignoring adopt request with wrong claim code")
        return true
    end

    cfgSet(cfg, "controller_id", payload.controller_id)
    cfgSet(cfg, "controller_token", payload.controller_token)
    cfgSave(cfg)
    logLine(logger, "[adopt] Adopted by controller " .. tostring(payload.controller_id))

    if type(onAdopted) == "function" then
        onAdopted(payload)
    end
    return true
end

return link