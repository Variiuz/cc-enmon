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
