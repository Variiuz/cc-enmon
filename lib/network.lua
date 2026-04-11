-- lib/network.lua
-- Ender modem helpers: open channel, typed message send/receive, HMAC validation.
--
-- Message wire format (textutils.serialize of this table):
--   {
--     type      = string,   -- message type constant (see MSG below)
--     sender_id = number,   -- os.getComputerID() of sender
--     node_id   = string,   -- config node_id of sender
--     payload   = table,    -- message-specific data
--     hmac      = string,   -- HMAC-SHA256(shared_secret, sender_id..type..serialize(payload))
--   }

local hmacLib = require("lib/hmac")

local net = {}

-- Message type constants
net.MSG = {
    MATRIX_DATA    = "MATRIX_DATA",
    REACTOR_DATA   = "REACTOR_DATA",
    DISPLAY_UPDATE = "DISPLAY_UPDATE",
    POCKET_REQUEST = "POCKET_REQUEST",
    POCKET_DATA    = "POCKET_DATA",
    CMD_REACTOR_SET = "CMD_REACTOR_SET",
}

local _modem   = nil
local _channel = 42
local _secret  = "enmon_default"
local _node_id = "unknown"

-- Open the ender modem and configure channel + secret.
-- modem: peripheral object (already wrapped)
-- channel: number
-- secret: string shared secret
-- node_id: string this node's ID
function net.open(modem, channel, secret, node_id)
    _modem   = modem
    _channel = channel
    _secret  = secret or "enmon_default"
    _node_id = node_id or tostring(os.getComputerID())
    modem.open(channel)
end

function net.close()
    if _modem then
        pcall(_modem.close, _modem, _channel)
        _modem = nil
    end
end

-- Compute HMAC tag for a message.
local function makeTag(msg_type, sender_id, payload)
    local data = tostring(sender_id) .. msg_type .. textutils.serialize(payload)
    return hmacLib.hmac256(_secret, data)
end

-- Send a typed message on the configured channel.
-- target_channel: optional override channel (nil = use configured channel)
function net.send(msg_type, payload, target_channel)
    if not _modem then return false, "modem not open" end
    local sender_id = os.getComputerID()
    local tag = makeTag(msg_type, sender_id, payload)
    local msg = textutils.serialize({
        type      = msg_type,
        sender_id = sender_id,
        node_id   = _node_id,
        payload   = payload,
        hmac      = tag,
    })
    local ch = target_channel or _channel
    local ok, err = pcall(_modem.transmit, _modem, ch, ch, msg)
    return ok, err
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
    if type(msg.payload)   ~= "table"  then return nil, "missing payload" end
    if type(msg.hmac)      ~= "string" then return nil, "missing hmac" end

    -- HMAC check
    local expected = makeTag(msg.type, msg.sender_id, msg.payload)
    if msg.hmac ~= expected then return nil, "hmac mismatch" end

    return msg, nil
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
