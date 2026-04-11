-- lib/util.lua
-- Shared utility functions: energy formatting, rate formatting, safe wrappers.

local util = {}

local SUFFIXES = {"", "k", "M", "G", "T", "P"}

-- Format an energy value (in RF) to a human-readable string with suffix.
-- e.g. 1500000 -> "1.50 MRF"
function util.formatEnergy(rf)
    if type(rf) ~= "number" then return "N/A" end
    local v = math.abs(rf)
    local idx = 1
    while v >= 1000 and idx < #SUFFIXES do
        v = v / 1000
        idx = idx + 1
    end
    if rf < 0 then v = -v end
    return string.format("%.2f %sRF", v, SUFFIXES[idx])
end

-- Format a per-tick rate (RF/t) to a human-readable string.
-- e.g. 50000 -> "50.00 kRF/t"
function util.formatRate(rf_t)
    if type(rf_t) ~= "number" then return "N/A" end
    local v = math.abs(rf_t)
    local idx = 1
    while v >= 1000 and idx < #SUFFIXES do
        v = v / 1000
        idx = idx + 1
    end
    if rf_t < 0 then v = -v end
    return string.format("%.2f %sRF/t", v, SUFFIXES[idx])
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

-- Timestamp string for display: HH:MM:SS
function util.timestamp()
    local t = os.time()
    return textutils.formatTime(t, true)
end

return util
