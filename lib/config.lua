-- lib/config.lua
-- Read/write enmon.cfg using textutils.serialize.
-- Config fields:
--   role         string  "controller" | "matrix" | "reactor" | "display" | "pocket"
--   node_id      string  unique identifier for this node (e.g. "matrix_1")
--   channel      number  ender modem channel (default 42)
--   modem_side   string  side/name of modem peripheral to bind for ENMON traffic
--   controller_id number  computer ID of the adopted controller (non-controller nodes)
--   controller_token string per-node operational auth token issued on adoption
--   monitor_side string  side/name of monitor peripheral (controller + display)
--   speaker_side string  side/name of speaker peripheral (controller, optional)
--   -- Controller-only --
--   auto_ctrl    boolean  enable automatic reactor control
--   threshold_low  number  matrix fill % to trigger reactor start  (default 0.25)
--   threshold_high number  matrix fill % to trigger reactor stop   (default 0.90)
--   update_check_interval number seconds between controller manifest checks (default 90)

local CONFIG_PATH = "enmon.cfg"
local CONFIG_VERSION = 7

local DEFAULTS = {
    role           = nil,
    node_id        = nil,
    channel        = 42,
    modem_side     = nil,
    controller_id  = nil,
    controller_token = nil,
    monitor_side   = nil,
    speaker_side   = nil,
    auto_ctrl      = true,
    threshold_low  = 0.25,
    threshold_high = 0.90,
    update_check_interval = 90,
    history_persistence_mode = "prompt_when_disk_detected",
    energy_unit = "FE",
}

local config = {}
local _data = {}
local _meta = {
    found = false,
    migrated = false,
    saved = false,
    from_version = 0,
    to_version = CONFIG_VERSION,
    notes = {},
}

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function cloneTable(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

local function note(meta, message)
    meta.notes[#meta.notes + 1] = message
end

local function normalizeThreshold(value, fallback)
    if value == nil then return fallback end
    local number = tonumber(value)
    if not number then return fallback end
    if number > 1 then
        number = number / 100
    end
    if number <= 0 then return fallback end
    if number >= 1 then return fallback end
    return number
end

local function normalizeInteger(value, fallback)
    if value == nil then return fallback end
    local number = tonumber(value)
    if not number then return fallback end
    return math.floor(number + 0.5)
end

local function normalizeText(value, fallback, allowBlank)
    if value == nil then return fallback end
    local text = trim(value)
    if text == "" and not allowBlank then return fallback end
    if text == "" and allowBlank then return nil end
    return text
end

local function normalizePersistenceMode(value, fallback)
    local text = normalizeText(value, fallback, false)
    if text == nil then return fallback end

    local aliases = {
        memory = "memory_only",
        memory_only = "memory_only",
        prompt = "prompt_when_disk_detected",
        prompt_when_disk_detected = "prompt_when_disk_detected",
        disk = "disk_enabled",
        disk_enabled = "disk_enabled",
    }

    return aliases[string.lower(text)] or fallback
end

local function normalizeEnergyUnit(value, fallback)
    local text = normalizeText(value, fallback, false)
    if text == nil then return fallback end
    text = string.upper(text)
    if text ~= "FE" and text ~= "RF" then
        return fallback
    end
    return text
end

local function sanitizeRoleConfig(data, meta)
    if data.role ~= "controller" then
        if data.speaker_side ~= nil then note(meta, "Removed controller-only speaker setting") end
        if data.auto_ctrl ~= nil then note(meta, "Removed controller-only auto control setting") end
        if data.threshold_low ~= nil or data.threshold_high ~= nil then
            note(meta, "Removed controller-only threshold settings")
        end
        if data.update_check_interval ~= nil then note(meta, "Removed controller-only update interval") end
        data.speaker_side = nil
        data.auto_ctrl = nil
        data.threshold_low = nil
        data.threshold_high = nil
        data.update_check_interval = nil
    else
        if data.controller_id ~= nil then note(meta, "Removed controller self-link setting") end
        if data.controller_token ~= nil then note(meta, "Removed controller self token") end
        data.controller_id = nil
        data.controller_token = nil
    end
    if data.role ~= "controller" and data.role ~= "display" then
        if data.monitor_side ~= nil then note(meta, "Removed monitor binding for non-monitor role") end
        data.monitor_side = nil
    end
end

local function normalizeData(input)
    local raw = cloneTable(input)
    local meta = {
        found = true,
        migrated = false,
        saved = false,
        from_version = tonumber(raw.config_version) or 0,
        to_version = CONFIG_VERSION,
        notes = {},
    }

    raw.role = normalizeText(raw.role, nil, false)
    raw.node_id = normalizeText(raw.node_id, nil, false)
    raw.modem_side = normalizeText(raw.modem_side, nil, true)
    raw.controller_token = normalizeText(raw.controller_token, nil, true)
    raw.monitor_side = normalizeText(raw.monitor_side, nil, true)
    raw.speaker_side = normalizeText(raw.speaker_side, nil, true)
    raw.channel = normalizeInteger(raw.channel, DEFAULTS.channel)
    raw.controller_id = normalizeInteger(raw.controller_id, nil)
    raw.update_check_interval = normalizeInteger(raw.update_check_interval, nil)
    raw.threshold_low = normalizeThreshold(raw.threshold_low, nil)
    raw.threshold_high = normalizeThreshold(raw.threshold_high, nil)
    raw.history_persistence_mode = normalizePersistenceMode(raw.history_persistence_mode, DEFAULTS.history_persistence_mode)
    raw.energy_unit = normalizeEnergyUnit(raw.energy_unit, DEFAULTS.energy_unit)

    if raw.auto_ctrl == nil then
        raw.auto_ctrl = DEFAULTS.auto_ctrl
    else
        raw.auto_ctrl = raw.auto_ctrl == true
    end

    if raw.role and raw.node_id == nil then
        raw.node_id = raw.role .. "_" .. tostring(os.getComputerID())
        note(meta, "Generated missing node ID from role and computer ID")
    end
    if raw.channel < 1 or raw.channel > 65535 then
        raw.channel = DEFAULTS.channel
        note(meta, "Reset invalid network channel to default")
    end
    if raw.controller_id ~= nil and raw.controller_id < 0 then
        raw.controller_id = nil
        note(meta, "Removed invalid controller computer ID")
    end
    if raw.shared_secret ~= nil then
        raw.shared_secret = nil
        note(meta, "Removed deprecated shared secret")
    end
    if raw.role == "controller" then
        if raw.threshold_low == nil then
            raw.threshold_low = DEFAULTS.threshold_low
            note(meta, "Applied default low threshold")
        end
        if raw.threshold_high == nil then
            raw.threshold_high = DEFAULTS.threshold_high
            note(meta, "Applied default high threshold")
        end
        if raw.threshold_low >= raw.threshold_high then
            raw.threshold_low = DEFAULTS.threshold_low
            raw.threshold_high = DEFAULTS.threshold_high
            note(meta, "Reset invalid threshold range to defaults")
        end
        if raw.update_check_interval == nil or raw.update_check_interval < 15 then
            raw.update_check_interval = DEFAULTS.update_check_interval
            note(meta, "Applied default controller update check interval")
        end
    end

    if raw.history_persistence_mode ~= "memory_only" and raw.history_persistence_mode ~= "prompt_when_disk_detected" and raw.history_persistence_mode ~= "disk_enabled" then
        raw.history_persistence_mode = DEFAULTS.history_persistence_mode
        note(meta, "Applied default history persistence mode")
    end
    if raw.energy_unit ~= "FE" and raw.energy_unit ~= "RF" then
        raw.energy_unit = DEFAULTS.energy_unit
        note(meta, "Applied default energy unit")
    end

    sanitizeRoleConfig(raw, meta)

    if raw.config_version ~= CONFIG_VERSION then
        raw.config_version = CONFIG_VERSION
        note(meta, "Updated config schema version")
    end

    meta.migrated = meta.from_version ~= CONFIG_VERSION or #meta.notes > 0
    return raw, meta
end

local function writeData()
    local f = fs.open(CONFIG_PATH, "w")
    f.write(textutils.serialize(_data))
    f.close()
end

function config.load()
    if not fs.exists(CONFIG_PATH) then
        _data = {}
        _meta = {
            found = false,
            migrated = false,
            saved = false,
            from_version = 0,
            to_version = CONFIG_VERSION,
            notes = {},
        }
        return false
    end
    local f = fs.open(CONFIG_PATH, "r")
    local raw = f.readAll()
    f.close()
    local ok, parsed = pcall(textutils.unserialize, raw)
    if ok and type(parsed) == "table" then
        _data, _meta = normalizeData(parsed)
        if _meta.migrated then
            writeData()
            _meta.saved = true
        end
        return true
    end
    _data = {}
    _meta = {
        found = true,
        migrated = false,
        saved = false,
        from_version = 0,
        to_version = CONFIG_VERSION,
        notes = { "Config parse failed" },
    }
    return false
end

function config.save()
    _data, _meta = normalizeData(_data)
    writeData()
    _meta.saved = true
end

function config.get(key)
    if _data[key] ~= nil then return _data[key] end
    return DEFAULTS[key]
end

function config.set(key, value)
    _data[key] = value
end

function config.replace(data)
    _data, _meta = normalizeData(data or {})
    return cloneTable(_data), cloneTable(_meta)
end

function config.exists()
    return fs.exists(CONFIG_PATH)
end

function config.delete()
    if fs.exists(CONFIG_PATH) then fs.delete(CONFIG_PATH) end
end

function config.export()
    local snapshot = {}
    for key, default in pairs(DEFAULTS) do
        if _data[key] ~= nil then
            snapshot[key] = _data[key]
        else
            snapshot[key] = default
        end
    end
    for key, value in pairs(_data) do
        if snapshot[key] == nil then
            snapshot[key] = value
        end
    end
    snapshot.config_version = _data.config_version or CONFIG_VERSION
    return snapshot
end

function config.getMetadata()
    local copy = cloneTable(_meta)
    copy.notes = cloneTable(_meta.notes)
    return copy
end

function config.getCurrentVersion()
    return CONFIG_VERSION
end

return config
