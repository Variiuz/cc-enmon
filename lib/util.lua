-- lib/util.lua
-- Shared utility functions: energy formatting, rate formatting, safe wrappers.

local util = {}

local SUFFIXES = {"", "k", "M", "G", "T", "P"}
local DEFAULT_ENERGY_UNIT = "FE"

function util.normalizeEnergyUnit(value, fallback)
    local text = tostring(value or fallback or DEFAULT_ENERGY_UNIT):upper()
    if text == "FE" or text == "RF" then
        return text
    end
    return tostring(fallback or DEFAULT_ENERGY_UNIT):upper()
end

function util.joulesToFe(value)
    if type(value) ~= "number" then return 0 end
    return value / 2.5
end

-- Format an energy value (in FE/RF) to a human-readable string with suffix.
function util.formatEnergy(value, unit)
    if type(value) ~= "number" then return "N/A" end
    local v = math.abs(value)
    local idx = 1
    while v >= 1000 and idx < #SUFFIXES do
        v = v / 1000
        idx = idx + 1
    end
    if value < 0 then v = -v end
    return string.format("%.2f %s%s", v, SUFFIXES[idx], util.normalizeEnergyUnit(unit, DEFAULT_ENERGY_UNIT))
end

function util.formatRate(value, unit)
    if type(value) ~= "number" then return "N/A" end
    local v = math.abs(value)
    local idx = 1
    while v >= 1000 and idx < #SUFFIXES do
        v = v / 1000
        idx = idx + 1
    end
    if value < 0 then v = -v end
    return string.format("%.2f %s%s/t", v, SUFFIXES[idx], util.normalizeEnergyUnit(unit, DEFAULT_ENERGY_UNIT))
end

-- Clamp a value between min and max.
function util.clamp(v, min, max)
    if v < min then return min end
    if v > max then return max end
    return v
end

-- Returns fill fraction [0.0, 1.0] given stored and max energy.
function util.fillFraction(stored, max)
    if type(max) ~= "number" or max <= 0 then return 0 end
    return util.clamp(stored / max, 0, 1)
end

-- Format a fill fraction as a percentage string. e.g. 0.753 -> "75.3%"
function util.formatPercent(fraction)
    if type(fraction) ~= "number" then return "N/A" end
    return string.format("%.1f%%", fraction * 100)
end

function util.formatDuration(seconds)
    local value = tonumber(seconds)
    if not value or value < 0 or value ~= value or value == math.huge then
        return "--"
    end
    value = math.floor(value + 0.5)
    if value < 60 then
        return tostring(value) .. "s"
    end
    if value < 3600 then
        local minutes = math.floor(value / 60)
        local secs = value % 60
        return string.format("%dm %02ds", minutes, secs)
    end
    local hours = math.floor(value / 3600)
    local minutes = math.floor((value % 3600) / 60)
    return string.format("%dh %02dm", hours, minutes)
end

-- Estimate time-to-empty / time-to-full from matrix IO rates (FE/t).
-- Returns eta_empty_s, eta_full_s, net_rate (positive = charging).
function util.estimateEnergyEta(energy, max_energy, last_input, last_output)
    local stored = tonumber(energy) or 0
    local capacity = tonumber(max_energy) or 0
    local input = tonumber(last_input) or 0
    local output = tonumber(last_output) or 0
    local net = input - output

    local eta_empty, eta_full = nil, nil
    if net < -1e-6 and stored > 0 then
        -- ticks at 20 t/s
        eta_empty = (stored / (-net)) / 20
    end
    if net > 1e-6 and capacity > stored then
        eta_full = ((capacity - stored) / net) / 20
    end
    return eta_empty, eta_full, net
end

function util.formatEnergyEta(energy, max_energy, last_input, last_output)
    local eta_empty, eta_full, net = util.estimateEnergyEta(energy, max_energy, last_input, last_output)
    if net > 1e-6 and eta_full then
        return "ETA full " .. util.formatDuration(eta_full), eta_empty, eta_full, net
    end
    if net < -1e-6 and eta_empty then
        return "ETA empty " .. util.formatDuration(eta_empty), eta_empty, eta_full, net
    end
    return "ETA --", eta_empty, eta_full, net
end

function util.formatTemperature(temp)
    if type(temp) ~= "number" then return "N/A" end
    return string.format("%.0fC", temp)
end

-- Safe call: wraps fn(...) in a pcall. On error, logs the message and returns nil.
-- Returns the first return value of fn on success.
function util.safeCall(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        -- result is the error message when pcall fails
        return nil, result
    end
    return result, nil
end

-- Timestamp string for display using ComputerCraft/Minecraft in-game time.
function util.timestamp()
    return textutils.formatTime(os.time(), true)
end

return util
