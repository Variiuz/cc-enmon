local net = require("lib/network")
local version = require("lib/version")
local hmacLib = require("lib/hmac")

local link = {}

local TOKEN_STORE_PATH = ".enmon_controller_tokens"
local CLAIM_PATH = ".enmon_claim"
local TOKEN_BYTES = 16
local CLAIM_CODE_BYTES = 4
local token_store = nil

do
    local seed = ((os.epoch and os.epoch("utc")) or (os.time() * 1000)) + (os.getComputerID() or 0) * 10007
    math.randomseed(seed % 2147483647)
    math.random()
    math.random()
    math.random()
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

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalizeClaim(value)
    local text = string.upper(trim(value):gsub("%s+", ""))
    if text == "" then return nil end
    return text
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
                role = entry.role,
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

local function deriveWrapKey(claim_code, node_id, sender_id)
    return hmacLib.hmac256(
        string.upper(claim_code),
        "enmon-adopt-wrap|" .. tostring(node_id) .. "|" .. tostring(sender_id)
    )
end

local function xorHexStrings(token_hex, key_hex)
    if type(token_hex) ~= "string" or type(key_hex) ~= "string" then
        return nil
    end
    if #token_hex == 0 or (#token_hex % 2) ~= 0 then
        return nil
    end
    if #key_hex < #token_hex then
        return nil
    end

    local out = {}
    for i = 1, #token_hex, 2 do
        local a = tonumber(token_hex:sub(i, i + 1), 16)
        local b = tonumber(key_hex:sub(i, i + 1), 16)
        if not a or not b then
            return nil
        end
        out[#out + 1] = string.format("%02x", bit32.bxor(a, b))
    end
    return table.concat(out)
end

function link.wrapAdoptToken(token, claim_code, node_id, sender_id)
    local key = deriveWrapKey(claim_code, node_id, sender_id)
    return xorHexStrings(token, key)
end

function link.unwrapAdoptToken(wrapped, claim_code, node_id, sender_id)
    local key = deriveWrapKey(claim_code, node_id, sender_id)
    return xorHexStrings(wrapped, key)
end

function link.newClaimCode()
    return string.upper(randomHex(CLAIM_CODE_BYTES))
end

function link.getOrCreateClaimCode()
    if fs.exists(CLAIM_PATH) then
        local file = fs.open(CLAIM_PATH, "r")
        if file then
            local existing = normalizeClaim(file.readAll())
            file.close()
            if existing and #existing >= 6 then
                return existing
            end
        end
    end

    local code = link.newClaimCode()
    local file = fs.open(CLAIM_PATH, "w")
    if file then
        file.write(code)
        file.close()
    end
    return code
end

function link.clearClaimCode()
    if fs.exists(CLAIM_PATH) then
        pcall(fs.delete, CLAIM_PATH)
    end
end

function link.promptClaimCode(message)
    local previous = term.getTextColor()
    term.setTextColor(colors.yellow)
    print(message or "Enter claim code from the node screen:")
    term.setTextColor(colors.white)
    write("> ")
    local input = read()
    term.setTextColor(previous)
    return normalizeClaim(input)
end

function link.promptYesNo(message, default_yes)
    local previous = term.getTextColor()
    local suffix = default_yes and " [Y/n]: " or " [y/N]: "
    while true do
        term.setTextColor(colors.yellow)
        write((message or "Confirm?") .. suffix)
        term.setTextColor(colors.white)
        local raw = string.lower(trim(read() or ""))
        if raw == "" then
            return default_yes == true
        end
        if raw == "y" or raw == "yes" then
            return true
        end
        if raw == "n" or raw == "no" then
            return false
        end
        term.setTextColor(colors.red)
        print("  Please enter y or n.")
        term.setTextColor(previous)
    end
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
    -- Never put claim codes on the wire.
    data.claim_code = nil
    return data
end

function link.buildDiscoveryPayload(cfg, role, claim_code, extra)
    local payload = cloneTable(extra)
    payload.role = role or cfgGet(cfg, "role")
    payload.local_version = version.getVersion()
    payload.status = payload.status or "unlinked"
    -- Claim codes are out-of-band only (shown on the node screen).
    payload.claim_code = nil
    payload.adopted = false
    payload.controller_id = nil
    return payload
end

function link.hasStoredToken(node_id)
    return getStoredEntry(node_id) ~= nil
end

function link.getStoredToken(node_id)
    local entry = getStoredEntry(node_id)
    if entry then
        return entry.token
    end

    return nil
end

function link.getStoredSenderId(node_id)
    local entry = getStoredEntry(node_id)
    if entry then
        return entry.sender_id
    end
    return nil
end

function link.storeNodeToken(node_id, sender_id, role, token, opts)
    if type(node_id) ~= "string" or node_id == "" then return nil, "bad-node-id" end
    if type(token) ~= "string" or token == "" then return nil, "bad-token" end

    opts = opts or {}
    local store = getTokenStore()
    if store[node_id] and opts.replace ~= true then
        return nil, "token-exists"
    end

    store[node_id] = {
        token = token,
        sender_id = tonumber(sender_id),
        role = role,
        adopted_at = os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000),
    }
    if not writeTokenStore(store) then
        return nil, "write-failed"
    end
    return token
end

function link.issueNodeToken(node_id, sender_id, role, opts)
    return link.storeNodeToken(node_id, sender_id, role, randomHex(TOKEN_BYTES), opts)
end

function link.buildControllerPayload(node_id, payload)
    local data = cloneTable(payload)
    data.controller_id = os.getComputerID()
    return data
end

function link.openControllerNetwork(cfg, modem)
    net.open(modem, cfgGet(cfg, "channel"), nil, cfgGet(cfg, "node_id"))
    net.setAuthResolver(function(msg)
        if msg.type == net.MSG.NODE_DISCOVERY then
            return { allowUnauthenticated = true, required = false }
        end

        local entry = getStoredEntry(msg.node_id)
        if entry and (entry.sender_id == nil or entry.sender_id == msg.sender_id) then
            return { keys = { entry.token }, required = true }
        end

        return { required = true }
    end)
end

function link.openNodeNetwork(cfg, modem, claim_code)
    net.open(modem, cfgGet(cfg, "channel"), nil, cfgGet(cfg, "node_id"))
    local normalized_claim = normalizeClaim(claim_code)
    net.setAuthResolver(function(msg)
        if msg.type == net.MSG.ADOPT_REQUEST and not link.isAdopted(cfg) then
            if normalized_claim then
                return { keys = { normalized_claim }, required = true }
            end
            return { required = true }
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

    local stored_sender = link.getStoredSenderId(msg and msg.node_id)
    if token and stored_sender ~= nil and msg and msg.sender_id ~= stored_sender then
        logLine(logger, "[auth] Ignoring node message with sender mismatch: " .. tostring(msg.node_id or "?"))
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
    local normalized_claim = normalizeClaim(claim_code)
    if not normalized_claim then
        logLine(logger, "[adopt] Ignoring adopt request; no local claim code")
        return true
    end

    if type(payload.controller_id) ~= "number" then
        logLine(logger, "[adopt] Ignoring malformed adopt request")
        return true
    end

    local token = nil
    if type(payload.wrapped_token) == "string" and payload.wrapped_token ~= "" then
        token = link.unwrapAdoptToken(payload.wrapped_token, normalized_claim, cfgGet(cfg, "node_id"), os.getComputerID())
        if not token then
            logLine(logger, "[adopt] Ignoring adopt request with invalid wrapped token")
            return true
        end
    elseif type(payload.controller_token) == "string" and payload.controller_token ~= "" then
        -- Legacy cleartext token path (pre-0.4.1 controllers).
        if type(payload.claim_code) == "string" and normalizeClaim(payload.claim_code) == normalized_claim then
            token = payload.controller_token
        else
            logLine(logger, "[adopt] Ignoring legacy adopt request with wrong claim code")
            return true
        end
    else
        logLine(logger, "[adopt] Ignoring malformed adopt request")
        return true
    end

    cfgSet(cfg, "controller_id", payload.controller_id)
    cfgSet(cfg, "controller_token", token)
    cfgSave(cfg)
    link.clearClaimCode()
    logLine(logger, "[adopt] Adopted by controller " .. tostring(payload.controller_id))

    if type(onAdopted) == "function" then
        onAdopted(payload)
    end
    return true
end

return link
