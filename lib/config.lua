-- lib/config.lua
-- Read/write enmon.cfg using textutils.serialize.
-- Config fields:
--   role         string  "controller" | "matrix" | "reactor" | "display" | "pocket"
--   node_id      string  unique identifier for this node (e.g. "matrix_1")
--   channel      number  ender modem channel (default 42)
--   controller_id string  computer ID of the controller (non-controller nodes)
--   monitor_side string  side/name of monitor peripheral (controller + display)
--   speaker_side string  side/name of speaker peripheral (controller, optional)
--   shared_secret string  HMAC secret; must match across all nodes in the network
--   -- Controller-only --
--   auto_ctrl    boolean  enable automatic reactor control
--   threshold_low  number  matrix fill % to trigger reactor start  (default 0.25)
--   threshold_high number  matrix fill % to trigger reactor stop   (default 0.90)

local CONFIG_PATH = "enmon.cfg"

local DEFAULTS = {
    role           = nil,
    node_id        = nil,
    channel        = 42,
    controller_id  = nil,
    monitor_side   = nil,
    speaker_side   = nil,
    shared_secret  = "enmon_default",
    auto_ctrl      = true,
    threshold_low  = 0.25,
    threshold_high = 0.90,
}

local config = {}
local _data = {}

function config.load()
    if not fs.exists(CONFIG_PATH) then
        _data = {}
        return false
    end
    local f = fs.open(CONFIG_PATH, "r")
    local raw = f.readAll()
    f.close()
    local ok, parsed = pcall(textutils.unserialize, raw)
    if ok and type(parsed) == "table" then
        _data = parsed
        -- Coerce numeric fields that must be numbers.
        -- Protects against configs written as strings (e.g. old wizard or manual edits).
        if _data.channel       ~= nil then _data.channel       = tonumber(_data.channel)       or DEFAULTS.channel end
        if _data.controller_id ~= nil then _data.controller_id = tonumber(_data.controller_id) end
        if _data.threshold_low  ~= nil then _data.threshold_low  = tonumber(_data.threshold_low)  end
        if _data.threshold_high ~= nil then _data.threshold_high = tonumber(_data.threshold_high) end
        return true
    end
    _data = {}
    return false
end

function config.save()
    local f = fs.open(CONFIG_PATH, "w")
    f.write(textutils.serialize(_data))
    f.close()
end

function config.get(key)
    if _data[key] ~= nil then return _data[key] end
    return DEFAULTS[key]
end

function config.set(key, value)
    _data[key] = value
end

function config.exists()
    return fs.exists(CONFIG_PATH)
end

function config.delete()
    if fs.exists(CONFIG_PATH) then fs.delete(CONFIG_PATH) end
end

return config
