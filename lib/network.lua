-- lib/network.lua
-- Ender modem helpers: open channel, typed message send/receive, and pluggable
-- message authentication.
--
-- Message wire format (textutils.serialize of this table):
--   {
--     type      = string,   -- message type constant (see MSG below)
--     sender_id = number,   -- os.getComputerID() of sender
--     node_id   = string,   -- config node_id of sender
--     target_node_id = string|nil,   -- optional node_id target filter
--     target_sender_id = number|nil, -- optional computer ID target filter
--     msg_id    = string|nil,        -- optional correlation ID for ACK/status
--     payload   = table,    -- message-specific data
--     hmac      = string|nil,   -- optional legacy HMAC
--     hmac_v2   = string|nil,   -- optional HMAC-SHA256 over sender identity + routing + payload
--   }

local hmacLib = require("lib/hmac")

local net = {}

-- Message type constants
net.MSG = {
    NODE_DISCOVERY = "NODE_DISCOVERY",
    NODE_HELLO     = "NODE_HELLO",
    MATRIX_DATA    = "MATRIX_DATA",
    REACTOR_DATA   = "REACTOR_DATA",
    DISPLAY_UPDATE = "DISPLAY_UPDATE",
    POCKET_REQUEST = "POCKET_REQUEST",
    POCKET_DATA    = "POCKET_DATA",
    CMD_REACTOR_SET = "CMD_REACTOR_SET",
    UPDATE_CHECK   = "UPDATE_CHECK",
    UPDATE_OFFER   = "UPDATE_OFFER",
    UPDATE_START   = "UPDATE_START",
    UPDATE_STATUS  = "UPDATE_STATUS",
    UPDATE_ACK     = "UPDATE_ACK",
    UPDATE_ABORT   = "UPDATE_ABORT",
    ADOPT_REQUEST  = "ADOPT_REQUEST",
}

local _modem   = nil
local _channel = 42
local _node_id = "unknown"
local _auth_resolver = nil

local function constantTimeEquals(left, right)
    if type(left) ~= "string" or type(right) ~= "string" then return false end
    if #left ~= #right then return false end

    local diff = 0
    for i = 1, #left do
        diff = bit32.bor(diff, bit32.bxor(left:byte(i), right:byte(i)))
    end
    return diff == 0
end

local function cloneTable(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

-- Open the ender modem and configure channel + secret.
-- modem: peripheral object (already wrapped)
-- channel: number
-- secret: deprecated, ignored unless no auth_key is provided for a message
-- node_id: string this node's ID
function net.open(modem, channel, secret, node_id)
    _modem   = modem
    _channel = channel
    _node_id = node_id or tostring(os.getComputerID())
    modem.open(channel)
end

function net.setAuthResolver(resolver)
    _auth_resolver = resolver
end

function net.close()
    if _modem then
        pcall(_modem.close, _channel)
        _modem = nil
    end
end

-- Legacy tag used so updated nodes can still communicate with pre-v2 peers during rollout.
local function makeLegacyTag(secret, msg_type, sender_id, payload, target_node_id, target_sender_id, msg_id)
    local data = textutils.serialize({
        type = msg_type,
        sender_id = sender_id,
        payload = payload,
        target_node_id = target_node_id,
        target_sender_id = target_sender_id,
        msg_id = msg_id,
    })
    return hmacLib.hmac256(secret, data)
end

local function makeTag(secret, msg_type, sender_id, node_id, payload, target_node_id, target_sender_id, msg_id)
    local data = textutils.serialize({
        type = msg_type,
        sender_id = sender_id,
        node_id = node_id,
        payload = payload,
        target_node_id = target_node_id,
        target_sender_id = target_sender_id,
        msg_id = msg_id,
    })
    return hmacLib.hmac256(secret, data)
end

local function normalizeResolverResult(result)
    if type(result) ~= "table" then
        return {
            keys = {},
            allowUnauthenticated = false,
            required = false,
        }
    end

    local keys = {}
    if type(result.keys) == "table" then
        for _, key in ipairs(result.keys) do
            if type(key) == "string" and key ~= "" then
                keys[#keys + 1] = key
            end
        end
    elseif type(result.key) == "string" and result.key ~= "" then
        keys[1] = result.key
    end

    return {
        keys = keys,
        allowUnauthenticated = result.allowUnauthenticated == true,
        required = result.required == true,
    }
end

local function resolveAuth(msg)
    local result = {
        keys = {},
        allowUnauthenticated = false,
        required = false,
    }

    if type(_auth_resolver) == "function" then
        local ok, resolved = pcall(_auth_resolver, msg)
        if ok then
            result = normalizeResolverResult(resolved)
        end
    end

    return result
end

-- Send a typed message on the configured channel.
-- target_channel: optional override channel (nil = use configured channel)
function net.send(msg_type, payload, target_channel, options)
    if not _modem then return false, "modem not open" end
    options = options or {}
    local sender_id = os.getComputerID()
    local msg_id = options.msg_id or (tostring(sender_id) .. ":" .. tostring(os.clock()) .. ":" .. tostring(math.random(1000, 9999)))
    local auth_key = options.auth_key
    local message = {
        type      = msg_type,
        sender_id = sender_id,
        node_id   = _node_id,
        target_node_id = options.target_node_id,
        target_sender_id = options.target_sender_id,
        msg_id    = msg_id,
        payload   = payload or {},
    }

    if type(auth_key) == "string" and auth_key ~= "" then
        message.hmac = makeLegacyTag(auth_key, msg_type, sender_id, message.payload, options.target_node_id, options.target_sender_id, msg_id)
        message.hmac_v2 = makeTag(auth_key, msg_type, sender_id, _node_id, message.payload, options.target_node_id, options.target_sender_id, msg_id)
    end

    local msg = textutils.serialize(message)
    local ch = target_channel or _channel
    local ok, err = pcall(_modem.transmit, ch, ch, msg)
    return ok, err, msg_id
end

function net.sendTargeted(msg_type, payload, target_node_id, target_sender_id, target_channel, msg_id_or_options)
    local options = {}
    if type(msg_id_or_options) == "table" then
        options = cloneTable(msg_id_or_options)
    elseif msg_id_or_options ~= nil then
        options.msg_id = msg_id_or_options
    end
    return net.send(msg_type, payload, target_channel, {
        target_node_id = target_node_id,
        target_sender_id = target_sender_id,
        msg_id = options.msg_id,
        auth_key = options.auth_key,
    })
end

-- Validate an incoming raw modem message string.
-- Returns parsed msg table on success, nil + reason on failure.
function net.validate(raw)
    if type(raw) ~= "string" then return nil, "not a string" end
    local ok, msg = pcall(textutils.unserialize, raw)
    if not ok or type(msg) ~= "table" then return nil, "parse error" end

    -- Structural check
    if type(msg.type)      ~= "string" then return nil, "missing type" end
    if type(msg.sender_id) ~= "number" then return nil, "missing sender_id" end
    if type(msg.node_id)   ~= "string" then return nil, "missing node_id" end
    if msg.target_node_id ~= nil and type(msg.target_node_id) ~= "string" then return nil, "bad target_node_id" end
    if msg.target_sender_id ~= nil and type(msg.target_sender_id) ~= "number" then return nil, "bad target_sender_id" end
    if msg.msg_id ~= nil and type(msg.msg_id) ~= "string" then return nil, "bad msg_id" end
    if type(msg.payload)   ~= "table"  then return nil, "missing payload" end
    if msg.hmac ~= nil and type(msg.hmac) ~= "string" then return nil, "bad hmac" end
    if msg.hmac_v2 ~= nil and type(msg.hmac_v2) ~= "string" then return nil, "bad hmac_v2" end

    local auth = resolveAuth(msg)
    for _, key in ipairs(auth.keys or {}) do
        local expectedV2 = makeTag(key, msg.type, msg.sender_id, msg.node_id, msg.payload, msg.target_node_id, msg.target_sender_id, msg.msg_id)
        if msg.hmac_v2 and constantTimeEquals(msg.hmac_v2, expectedV2) then
            msg.auth_version = 2
            return msg, nil
        end

        local expectedLegacy = makeLegacyTag(key, msg.type, msg.sender_id, msg.payload, msg.target_node_id, msg.target_sender_id, msg.msg_id)
        if msg.hmac and constantTimeEquals(msg.hmac, expectedLegacy) then
            msg.auth_version = 1
            return msg, nil
        end
    end

    if auth.allowUnauthenticated == true and msg.hmac == nil and msg.hmac_v2 == nil then
        msg.auth_version = 0
        return msg, nil
    end

    if auth.required == true then
        return nil, "auth required"
    end

    return nil, "auth mismatch"
end

function net.isTargetedToSelf(msg)
    if type(msg) ~= "table" then return false end
    if msg.target_node_id ~= nil and msg.target_node_id ~= _node_id then
        return false
    end
    if msg.target_sender_id ~= nil and msg.target_sender_id ~= os.getComputerID() then
        return false
    end
    return true
end

-- Blocking receive. Waits for a validated ENMON message on the configured channel.
-- timeout: seconds to wait (nil = wait forever)
-- filter: optional table of msg type strings to accept (nil = accept all)
-- Returns msg table, reply_channel on success, or nil, reason on timeout/error.
function net.receive(timeout, filter)
    if not _modem then return nil, "modem not open" end
    local timer_id
    if timeout then
        timer_id = os.startTimer(timeout)
    end

    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()

        if event == "modem_message" then
            -- p1=side, p2=sender_ch, p3=reply_ch, p4=message
            local side, sender_ch, reply_ch, raw = p1, p2, p3, p4
            if sender_ch == _channel then
                local msg, err = net.validate(raw)
                if msg then
                    if not filter then
                        if timer_id then os.cancelTimer(timer_id) end
                        return msg, reply_ch
                    else
                        for _, t in ipairs(filter) do
                            if msg.type == t then
                                if timer_id then os.cancelTimer(timer_id) end
                                return msg, reply_ch
                            end
                        end
                        -- filtered out — keep waiting
                    end
                end
                -- invalid message — silently discard, keep waiting
            end

        elseif event == "timer" and p1 == timer_id then
            return nil, "timeout"
        end
    end
end

return net
